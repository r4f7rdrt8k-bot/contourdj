#include "CDJCore.h"
#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <memory>
#include <mutex>
#include <vector>

namespace {
constexpr double pi = 3.14159265358979323846;
constexpr uint64_t memoryBudget = 1024ull * 1024 * 1024;
constexpr uint32_t recordCapacity = 1u << 19; // ~10.9s @48k, 4MiB stereo
template<class T> T clamp(T x, T lo, T hi) { return std::max(lo, std::min(x, hi)); }
double finite(double x, double fallback=0) { return std::isfinite(x) ? x : fallback; }
struct Track { std::vector<float> pcm; uint64_t frames=0; double rate=48000; };
struct Deck {
    std::atomic<Track*> track{nullptr}, hazard{nullptr};
    std::atomic<bool> playing{false}, reverse{false}, looping{false};
    std::atomic<double> rate{1}, volume{0.8}, low{0}, mid{0}, high{0}, filter{0};
    std::atomic<int> effect{0}; std::atomic<double> wet{0};
    std::atomic<double> seek{0}, publicPosition{0}, loopStart{0}, loopEnd{0};
    std::atomic<uint64_t> seekVersion{0};
    Track *active=nullptr; uint64_t seenSeek=0;
    double position=0, smoothVolume=0, smoothRate=1, fxPhase=0;
    bool wasPlaying=false;
    float lowState[2]{}, highState[2]{}, filterState[2]{};
    std::vector<float> delay; uint32_t delayWrite=0;
    uint32_t silentDelayFrames=0;
    double cachedEQ[3]{NAN,NAN,NAN}, gains[3]{1,1,1}, cachedFilter=NAN;
    float filterA=0;
};
float softLimit(float x) {
    if (!std::isfinite(x)) return 0;
    const float a=std::abs(x);
    if (a <= 0.9f) return x;
    return std::copysign(0.9f + 0.1f * std::tanh((a-0.9f)*10), x);
}
}

struct CDJEngine {
    double sampleRate;
    float lowA,highA;
    double fxStep,kickPitchDecay,kickDecay,snareDecay,hatDecay;
    uint32_t echoBack,reverbBack[4];
    std::array<Deck,4> decks;
    std::mutex storageMutex; // NEVER acquired by render
    std::vector<std::unique_ptr<Track>> tracks;
    std::atomic<double> crossfader{0.5}, master{0.8};
    double smoothMaster=0.8, smoothCrossfader=0.5;
    std::atomic<float> peak{0};
    std::atomic<bool> patternEnabled{false};
    std::atomic<double> patternBpm{120}, patternVolume{0.4};
    double patternPhase=0, kickAge=10, snareAge=10, hatAge=10;
    double kickPitch=std::exp(-300.0),kickEnvelope=std::exp(-160.0),snareEnvelope=std::exp(-240.0),hatEnvelope=0;
    uint32_t random=0x12345678; int oldStep=-1;
    std::vector<float> recordRing;
    std::atomic<uint64_t> recordRead{0}, recordWrite{0}, dropped{0};
    std::atomic<bool> recording{false};
    std::atomic<uint32_t> recordingWriters{0};
    explicit CDJEngine(double sr):sampleRate(sr), recordRing(recordCapacity*2,0) {
        lowA=1-std::exp(-2*pi*250/sr);highA=1-std::exp(-2*pi*4000/sr);
        fxStep=2*pi*0.2/sr;
        kickPitchDecay=std::exp(-30/sr);kickDecay=std::exp(-16/sr);
        snareDecay=std::exp(-24/sr);hatDecay=std::exp(-100/sr);
        echoBack=uint32_t(sr*.375);
        const double taps[]{.047,.113,.173,.229};
        for(int i=0;i<4;++i)reverbBack[i]=uint32_t(sr*taps[i]);
        for(auto &d: decks){d.delay.assign(static_cast<size_t>(std::ceil(sr*2))*2,0);d.silentDelayFrames=uint32_t(d.delay.size()/2);}
    }
};

namespace {
Deck *deck(CDJEngine *e,int n) { return e && n>=0 && n<4 ? &e->decks[n] : nullptr; }
void reclaimLocked(CDJEngine *e) {
    // Sequentially consistent hazard publication + pointer recheck in render
    // prevents a loader from freeing a buffer the render callback is using.
    e->tracks.erase(std::remove_if(e->tracks.begin(),e->tracks.end(),[&](auto &p){
        for(auto &d:e->decks)
            if(d.track.load()==p.get() || d.hazard.load()==p.get()) return false;
        return true;
    }),e->tracks.end());
}
Track *protect(Deck &d) {
    Track *p;
    do { p=d.track.load(); d.hazard.store(p); } while(p!=d.track.load());
    return p;
}
float readDelay(Deck &d, uint32_t back, int ch) {
    const uint32_t size=static_cast<uint32_t>(d.delay.size()/2);
    // Every supported tap is shorter than the two-second ring. Conditional
    // wrap avoids two variable integer divisions for every channel/tap/sample.
    const uint32_t at=d.delayWrite>=back?d.delayWrite-back:d.delayWrite+size-back;
    return d.delay[at*2+ch];
}
void recordOutput(CDJEngine *e,const float *left,const float *right,uint32_t frames){
    e->recordingWriters.fetch_add(1);
    if(e->recording.load()){
        const uint64_t w=e->recordWrite.load(std::memory_order_relaxed),r=e->recordRead.load(std::memory_order_acquire);
        const uint32_t available=uint32_t(std::min<uint64_t>(frames,recordCapacity-(w-r)));
        for(uint32_t i=0;i<available;++i){uint32_t at=uint32_t(w+i)&(recordCapacity-1);e->recordRing[at*2]=left[i];e->recordRing[at*2+1]=right[i];}
        e->recordWrite.store(w+available,std::memory_order_release);
        e->dropped.fetch_add(frames-available,std::memory_order_relaxed);
    }
    e->recordingWriters.fetch_sub(1);
}
}

extern "C" {
CDJEngine *cdj_create(double sr) {
    if(!std::isfinite(sr) || sr<8000 || sr>192000) return nullptr;
    try { return new CDJEngine(sr); } catch(...) { return nullptr; }
}
void cdj_destroy(CDJEngine *e) { delete e; }
void cdj_reclaim(CDJEngine *e) { if(e){std::lock_guard<std::mutex> l(e->storageMutex);reclaimLocked(e);} }
bool cdj_load(CDJEngine *e,int n,const float *pcm,uint64_t count,double sr) {
    auto d=deck(e,n); if(!d || !pcm || count<2 || count>32000000 || sr<8000 || sr>192000 || !std::isfinite(sr)) return false;
    try {
        std::lock_guard<std::mutex> lock(e->storageMutex);
        reclaimLocked(e);
        uint64_t used=count*2*sizeof(float);
        for(auto &p:e->tracks) used+=p->pcm.size()*sizeof(float);
        if(used>memoryBudget) return false;
        auto p=std::make_unique<Track>(); p->frames=count; p->rate=sr;
        p->pcm.assign(pcm,pcm+count*2);
        for(float &x:p->pcm) if(!std::isfinite(x)) x=0;
        auto raw=p.get(); e->tracks.push_back(std::move(p));
        d->playing.store(false); d->looping.store(false); d->reverse.store(false);
        d->seek.store(0); d->seekVersion.fetch_add(1); d->publicPosition.store(0);
        d->track.store(raw); reclaimLocked(e);
        return true;
    } catch(...) { return false; }
}
void cdj_play(CDJEngine *e,int n,bool v){if(auto d=deck(e,n))d->playing.store(v);}
bool cdj_is_playing(CDJEngine *e,int n){auto d=deck(e,n);return d&&d->playing.load();}
void cdj_seek(CDJEngine *e,int n,double v){if(auto d=deck(e,n)){v=std::max(0.0,finite(v));d->seek.store(v);d->seekVersion.fetch_add(1);d->publicPosition.store(v);}}
double cdj_position(CDJEngine *e,int n){auto d=deck(e,n);return d?d->publicPosition.load():0;}
void cdj_rate(CDJEngine *e,int n,double v){if(auto d=deck(e,n))d->rate.store(clamp(finite(v,1.0),0.25,4.0));}
void cdj_volume(CDJEngine *e,int n,double v){if(auto d=deck(e,n))d->volume.store(clamp(finite(v),0.0,2.0));}
void cdj_eq(CDJEngine *e,int n,double l,double m,double h){if(auto d=deck(e,n)){d->low.store(clamp(finite(l),-36.0,12.0));d->mid.store(clamp(finite(m),-36.0,12.0));d->high.store(clamp(finite(h),-36.0,12.0));}}
void cdj_filter(CDJEngine *e,int n,double v){if(auto d=deck(e,n))d->filter.store(clamp(finite(v),-1.0,1.0));}
void cdj_effect(CDJEngine *e,int n,int k,double m){if(auto d=deck(e,n)){d->effect.store(clamp(k,0,3));d->wet.store(clamp(finite(m),0.0,1.0));}}
void cdj_crossfader(CDJEngine *e,double v){if(e)e->crossfader.store(clamp(finite(v,0.5),0.0,1.0));}
void cdj_master(CDJEngine *e,double v){if(e)e->master.store(clamp(finite(v),0.0,2.0));}
void cdj_loop(CDJEngine *e,int n,double a,double b,bool on){if(auto d=deck(e,n)){a=std::max(0.0,finite(a));b=std::max(a,finite(b));d->loopStart.store(a);d->loopEnd.store(b);d->looping.store(on&&b>a+0.001);}}
void cdj_reverse(CDJEngine *e,int n,bool v){if(auto d=deck(e,n))d->reverse.store(v);}
void cdj_pattern(CDJEngine *e,bool on,double bpm,double v){if(e){e->patternBpm.store(clamp(finite(bpm,120),40.0,240.0));e->patternVolume.store(clamp(finite(v),0.0,1.0));e->patternEnabled.store(on);}}
float cdj_peak(CDJEngine *e){return e?e->peak.load():0;}

void cdj_render(CDJEngine *e,float *left,float *right,uint32_t frames) {
    if(!e||!left||!right)return;
    std::fill(left,left+frames,0); std::fill(right,right+frames,0);
    const double xf=e->crossfader.load();
    const double xfStart=e->smoothCrossfader;
    const bool crossMoving=xf!=xfStart;
    const double angle=(xfStart+(xf-xfStart)/std::max(1u,frames))*pi*0.5;
    const double crossSinStart=std::sin(angle),crossCosStart=std::cos(angle);
    const double angleStep=(xf-xfStart)*pi*0.5/std::max(1u,frames);
    const double crossSinStep=crossMoving?std::sin(angleStep):0,crossCosStep=crossMoving?std::cos(angleStep):1;
    bool hasDeckSignal=false;
    for(int index=0;index<4;++index){
        auto &d=e->decks[index]; Track *t=protect(d);
        if(!t){d.hazard.store(nullptr);continue;}
        if(t!=d.active){
            d.active=t;d.position=0;d.wasPlaying=false;
            std::fill(std::begin(d.lowState),std::end(d.lowState),0);
            std::fill(std::begin(d.highState),std::end(d.highState),0);
            std::fill(std::begin(d.filterState),std::end(d.filterState),0);
        }
        auto seekVersion=d.seekVersion.load();
        if(seekVersion!=d.seenSeek){d.position=clamp(d.seek.load()*t->rate,0.0,double(t->frames-1));d.seenSeek=seekVersion;}
        bool playing=d.playing.load(),reverse=d.reverse.load();
        if(playing&&!d.wasPlaying&&reverse&&d.position<=0)d.position=t->frames-1;
        d.wasPlaying=playing;
        const double targetVolume=d.volume.load(),targetRate=d.rate.load();
        const double db[3]{d.low.load(),d.mid.load(),d.high.load()};
        for(int band=0;band<3;++band)if(db[band]!=d.cachedEQ[band]){d.cachedEQ[band]=db[band];d.gains[band]=std::pow(10.0,db[band]/20);}
        const double *gains=d.gains;
        const float lowA=e->lowA,highA=e->highA;
        const double filter=d.filter.load();
        if(filter!=d.cachedFilter){
            d.cachedFilter=filter;
            const double cutoff=filter<0 ? 40*std::pow(450.0,1+filter) : 40*std::pow(450.0,filter);
            d.filterA=1-std::exp(-2*pi*std::min(cutoff,e->sampleRate*0.45)/e->sampleRate);
        }
        const float filterA=d.filterA;
        const int effect=d.effect.load(); const float wet=d.wet.load();
        double loopA=clamp(d.loopStart.load()*t->rate,0.0,double(t->frames-1));
        double loopB=clamp(d.loopEnd.load()*t->rate,0.0,double(t->frames));
        bool looping=d.looping.load()&&loopB-loopA>=2;
        const bool volumeMoving=d.smoothVolume+(targetVolume-d.smoothVolume)*0.003!=d.smoothVolume;
        const bool rateMoving=d.smoothRate+(targetRate-d.smoothRate)*0.003!=d.smoothRate;
        const uint32_t delayFrames=uint32_t(d.delay.size()/2);
        // This is an exact-zero shortcut, not a level gate: no filter state,
        // reverb/echo/flanger history or subnormal tail is discarded. Advance
        // the original recurrences and phase so resuming remains continuous.
        if(!playing&&d.silentDelayFrames==delayFrames&&d.lowState[0]==0&&d.lowState[1]==0&&d.highState[0]==0&&d.highState[1]==0&&d.filterState[0]==0&&d.filterState[1]==0){
            for(uint32_t i=0;i<frames;++i){
                if(volumeMoving)d.smoothVolume+=(targetVolume-d.smoothVolume)*0.003;
                if(rateMoving)d.smoothRate+=(targetRate-d.smoothRate)*0.003;
                d.fxPhase+=e->fxStep;if(d.fxPhase>2*pi)d.fxPhase-=2*pi;
            }
            d.delayWrite=uint32_t((uint64_t(d.delayWrite)+frames)%delayFrames);
            d.publicPosition.store(clamp(d.position/t->rate,0.0,double(t->frames)/t->rate));
            d.hazard.store(nullptr);continue;
        }
        hasDeckSignal=true;
        double crossSin=crossSinStart,crossCos=crossCosStart;
        for(uint32_t i=0;i<frames;++i){
            if(volumeMoving)d.smoothVolume+=(targetVolume-d.smoothVolume)*0.003;
            if(rateMoving)d.smoothRate+=(targetRate-d.smoothRate)*0.003;
            float v[2]{};
            if(playing){
                if(looping&&(d.position>=loopB||d.position<loopA)){
                    double offset=std::fmod(d.position-loopA,loopB-loopA);
                    if(offset<0)offset+=loopB-loopA;d.position=loopA+offset;
                }
                if(d.position<0||d.position>=double(t->frames)){
                    playing=false;d.playing.store(false);d.position=clamp(d.position,0.0,double(t->frames));
                }else{
                    uint64_t a=static_cast<uint64_t>(d.position), b=std::min(a+1,t->frames-1);
                    if(looping&&double(b)>=loopB)b=static_cast<uint64_t>(loopA);
                    float f=d.position-a;
                    for(int ch=0;ch<2;++ch)v[ch]=t->pcm[a*2+ch]*(1-f)+t->pcm[b*2+ch]*f;
                    d.position+=(reverse?-1:1)*d.smoothRate*t->rate/e->sampleRate;
                }
            }
            float processed[2];
            bool silentWrite=true;
            for(int ch=0;ch<2;++ch){
                d.lowState[ch]+=lowA*(v[ch]-d.lowState[ch]);
                d.highState[ch]+=highA*(v[ch]-d.highState[ch]);
                float x=d.lowState[ch]*gains[0]+(d.highState[ch]-d.lowState[ch])*gains[1]+(v[ch]-d.highState[ch])*gains[2];
                d.filterState[ch]+=filterA*(x-d.filterState[ch]);
                if(std::abs(filter)>0.015)x=filter<0?d.filterState[ch]:x-d.filterState[ch];
                float tail=0;
                if(effect==1)tail=readDelay(d,e->echoBack,ch);
                else if(effect==2)tail=(readDelay(d,e->reverbBack[0],ch)+readDelay(d,e->reverbBack[1],1-ch)+readDelay(d,e->reverbBack[2],ch)+readDelay(d,e->reverbBack[3],1-ch))*0.25f;
                else if(effect==3)tail=readDelay(d,uint32_t(e->sampleRate*(0.0035+0.0025*std::sin(d.fxPhase+ch*0.4))),ch);
                d.delay[d.delayWrite*2+ch]=x+tail*(effect==2?0.65f:0.35f);
                silentWrite&=d.delay[d.delayWrite*2+ch]==0;
                processed[ch]=x*(1-wet*(effect?0.65f:0))+tail*wet;
            }
            d.silentDelayFrames=silentWrite?std::min(delayFrames,d.silentDelayFrames+1):0;
            if(++d.delayWrite==delayFrames)d.delayWrite=0;
            d.fxPhase+=e->fxStep;if(d.fxPhase>2*pi)d.fxPhase-=2*pi;
            const float cross=index%2==0?crossCos:crossSin;
            left[i]+=processed[0]*d.smoothVolume*cross;
            right[i]+=processed[1]*d.smoothVolume*cross;
            if(crossMoving){const double previousSin=crossSin;crossSin=crossSin*crossCosStep+crossCos*crossSinStep;crossCos=crossCos*crossCosStep-previousSin*crossSinStep;}
        }
        if(looping&&playing){double o=std::fmod(d.position-loopA,loopB-loopA);if(o<0)o+=loopB-loopA;d.position=loopA+o;}
        d.publicPosition.store(clamp(d.position/t->rate,0.0,double(t->frames)/t->rate));
        d.hazard.store(nullptr);
    }
    e->smoothCrossfader=xf;
    const bool pattern=e->patternEnabled.load();
    const double bpm=e->patternBpm.load(),pv=e->patternVolume.load(),master=e->master.load();
    const bool masterMoving=e->smoothMaster+(master-e->smoothMaster)*0.003!=e->smoothMaster;
    if(!pattern&&frames)e->oldStep=-1;
    if(!hasDeckSignal&&!pattern){
        if(masterMoving)for(uint32_t i=0;i<frames;++i)e->smoothMaster+=(master-e->smoothMaster)*0.003;
        e->peak.store(0);recordOutput(e,left,right,frames);return;
    }
    float peak=0;
    for(uint32_t i=0;i<frames;++i){
        float drum=0;
        if(pattern){
            int step=int(e->patternPhase)%16;
            if(step!=e->oldStep){if(step%8==0){e->kickAge=0;e->kickPitch=1;e->kickEnvelope=1;}if(step==4||step==12){e->snareAge=0;e->snareEnvelope=1;}if(step%2==0){e->hatAge=0;e->hatEnvelope=1;}e->oldStep=step;}
            e->random^=e->random<<13;e->random^=e->random>>17;e->random^=e->random<<5;
            const float noise=float(e->random)/2147483648.0f-1;
            drum=std::sin(2*pi*(48*e->kickAge+5*(1-e->kickPitch)))*e->kickEnvelope*0.8;
            drum+=noise*e->snareEnvelope*0.3+noise*e->hatEnvelope*0.13;
            e->kickAge+=1/e->sampleRate;e->snareAge+=1/e->sampleRate;e->hatAge+=1/e->sampleRate;
            e->kickPitch*=e->kickPitchDecay;e->kickEnvelope*=e->kickDecay;e->snareEnvelope*=e->snareDecay;e->hatEnvelope*=e->hatDecay;
            e->patternPhase+=bpm*4/(60*e->sampleRate);if(e->patternPhase>=16)e->patternPhase-=16;
        }
        if(masterMoving)e->smoothMaster+=(master-e->smoothMaster)*0.003;
        left[i]=softLimit((left[i]+drum*pv)*e->smoothMaster);
        right[i]=softLimit((right[i]+drum*pv)*e->smoothMaster);
        peak=std::max(peak,std::max(std::abs(left[i]),std::abs(right[i])));
    }
    e->peak.store(peak);
    // Audio callback only writes a fixed ring; the writer owns all file I/O.
    recordOutput(e,left,right,frames);
}
bool cdj_record_begin(CDJEngine *e){if(!e||e->recording.load())return false;e->recordRead.store(0);e->recordWrite.store(0);e->dropped.store(0);e->recording.store(true);return true;}
void cdj_record_end(CDJEngine *e){if(e)e->recording.store(false);}
uint32_t cdj_record_drain(CDJEngine *e,float *pcm,uint32_t maxFrames){
    if(!e||!pcm)return 0;
    // After stop, waiting is confined to the writer/control thread, never RT.
    if(!e->recording.load())while(e->recordingWriters.load()){}
    uint64_t r=e->recordRead.load(std::memory_order_relaxed),w=e->recordWrite.load(std::memory_order_acquire);
    uint32_t n=uint32_t(std::min<uint64_t>(maxFrames,w-r));
    for(uint32_t i=0;i<n;++i){uint32_t at=uint32_t(r+i)&(recordCapacity-1);pcm[i*2]=e->recordRing[at*2];pcm[i*2+1]=e->recordRing[at*2+1];}
    e->recordRead.store(r+n,std::memory_order_release);return n;
}
uint64_t cdj_record_dropped(CDJEngine *e){return e?e->dropped.load():0;}
}
