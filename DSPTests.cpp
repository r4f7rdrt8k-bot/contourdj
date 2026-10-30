#include "CDJCore.h"
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <fstream>
#include <functional>
#include <iostream>
#include <new>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

// This catches C++ allocations/deallocations inside cdj_render, not every
// possible libc allocator. Source review additionally checks file I/O/locks.
thread_local bool insideRender=false;
std::atomic<uint64_t> renderAllocations{0}, renderFrees{0};
void* operator new(std::size_t n) { if(insideRender)++renderAllocations; if(auto p=std::malloc(n?n:1))return p; throw std::bad_alloc(); }
void* operator new[](std::size_t n) { return ::operator new(n); }
void operator delete(void* p) noexcept { if(insideRender&&p)++renderFrees;std::free(p); }
void operator delete[](void* p) noexcept { ::operator delete(p); }
void operator delete(void* p,std::size_t) noexcept { ::operator delete(p); }
void operator delete[](void* p,std::size_t) noexcept { ::operator delete(p); }

namespace {
constexpr double pi=3.14159265358979323846;
void check(bool v,const std::string &message){if(!v)throw std::runtime_error(message);}
void near(double a,double b,double eps,const std::string &message){check(std::abs(a-b)<=eps,message);}
struct Mixer {
    CDJEngine *p;
    explicit Mixer(double sr=8000):p(cdj_create(sr)){check(p,"create");}
    ~Mixer(){cdj_destroy(p);}
    void load(const std::vector<float>&x,int deck=0,double rate=8000){check(cdj_load(p,deck,x.data(),x.size()/2,rate),"load");}
};
struct Audio { std::vector<float> l,r; explicit Audio(uint32_t n):l(n),r(n){} };
Audio render(CDJEngine *p,uint32_t n){Audio a(n);insideRender=true;cdj_render(p,a.l.data(),a.r.data(),n);insideRender=false;return a;}
std::vector<float> tone(double hz,int seconds=4,double sr=8000){std::vector<float>x(size_t(sr*seconds)*2);for(size_t i=0;i<x.size()/2;++i)x[i*2]=x[i*2+1]=float(std::sin(i*2*pi*hz/sr)*0.2);return x;}
double rms(const std::vector<float>&a,size_t start=0){double s=0;for(size_t i=start;i<a.size();++i)s+=double(a[i])*a[i];return std::sqrt(s/std::max<size_t>(1,a.size()-start));}
void unity(Mixer &e){cdj_crossfader(e.p,0);cdj_master(e.p,1);for(int i=0;i<4;++i)cdj_volume(e.p,i,1);render(e.p,8000);}
void finiteAudio(const Audio&a){for(float x:a.l)check(std::isfinite(x)&&std::abs(x)<=1,"finite bounded left");for(float x:a.r)check(std::isfinite(x)&&std::abs(x)<=1,"finite bounded right");}
std::string escaped(std::string s){std::string out;for(char c:s){if(c=='"'||c=='\\')out+='\\';if(c=='\n')out+="\\n";else out+=c;}return out;}
void le16(std::ofstream&f,uint16_t v){char b[]={char(v),char(v>>8)};f.write(b,2);}
void le32(std::ofstream&f,uint32_t v){char b[]={char(v),char(v>>8),char(v>>16),char(v>>24)};f.write(b,4);}
void wav(const std::string&path,const Audio&a,uint32_t rate){std::ofstream f(path,std::ios::binary);check(bool(f),"WAV open");f.write("RIFF",4);le32(f,uint32_t(a.l.size()*4+36));f.write("WAVEfmt ",8);le32(f,16);le16(f,1);le16(f,2);le32(f,rate);le32(f,rate*4);le16(f,4);le16(f,16);f.write("data",4);le32(f,uint32_t(a.l.size()*4));for(size_t i=0;i<a.l.size();++i){le16(f,uint16_t(int16_t(std::lrint(a.l[i]*32767))));le16(f,uint16_t(int16_t(std::lrint(a.r[i]*32767))));}check(bool(f),"WAV write");}
}

int main(int argc,char**argv){
    std::vector<std::pair<std::string,std::function<void()>>> tests;
    tests.push_back({"crossfader_stereo_routing",[]{
        Mixer e;std::vector<float>a(64000),b(64000);for(size_t i=0;i<a.size()/2;++i){a[i*2]=0.25;b[i*2+1]=0.25;}
        e.load(a);e.load(b,1);unity(e);cdj_play(e.p,0,true);cdj_play(e.p,1,true);
        auto out=render(e.p,4000);near(out.l.back(),.25,.001,"deckA audible");near(out.r.back(),0,.0001,"deckB rejected");
        cdj_crossfader(e.p,1);render(e.p,500);out=render(e.p,500);near(out.l.back(),0,.0001,"deckA rejected");near(out.r.back(),.25,.001,"deckB audible");
        cdj_crossfader(e.p,.5);render(e.p,500);out=render(e.p,500);near(out.l.back(),.25/std::sqrt(2),.001,"equal-power A");near(out.r.back(),.25/std::sqrt(2),.001,"equal-power B");
    }});
    tests.push_back({"loop_bounds_and_audio",[]{Mixer e;e.load(tone(100));unity(e);cdj_loop(e.p,0,.02,.04,true);cdj_play(e.p,0,true);auto a=render(e.p,9531);check(cdj_position(e.p,0)>=.02&&cdj_position(e.p,0)<.04,"loop bounds");check(cdj_is_playing(e.p,0),"loop playing");check(rms(a.l,1000)>.05,"loop nonzero");}});
    tests.push_back({"reverse_samples_and_position",[]{Mixer e;std::vector<float>a(32000);for(size_t i=0;i<a.size()/2;++i)a[i*2]=a[i*2+1]=float(i)/80000;e.load(a);unity(e);cdj_seek(e.p,0,1);cdj_reverse(e.p,0,true);cdj_play(e.p,0,true);auto o=render(e.p,400);check(o.l.front()>o.l.back(),"reverse descending samples");near(cdj_position(e.p,0),.95,.0001,"reverse source time");}});
    tests.push_back({"rate_changes_source_time",[]{Mixer e;e.load(tone(120));unity(e);cdj_rate(e.p,0,2);cdj_play(e.p,0,true);render(e.p,8000);check(cdj_position(e.p,0)>1.9&&cdj_position(e.p,0)<=2,"rate2 position");}});
    tests.push_back({"low_EQ_signal_attenuation",[]{Mixer e;e.load(tone(60));unity(e);cdj_play(e.p,0,true);auto dry=render(e.p,8000);cdj_eq(e.p,0,-36,0,0);auto cut=render(e.p,8000);check(rms(cut.l,2000)<rms(dry.l,2000)*.4,"low EQ measured attenuation");}});
    tests.push_back({"lowpass_signal_attenuation",[]{Mixer e;e.load(tone(2000));unity(e);cdj_play(e.p,0,true);auto dry=render(e.p,8000);cdj_filter(e.p,0,-1);auto cut=render(e.p,8000);check(rms(cut.l,2000)<rms(dry.l,2000)*.1,"LP measured attenuation");}});
    tests.push_back({"echo_delayed_impulse",[]{Mixer e;std::vector<float>x(32000);x[2000]=x[2001]=.3;e.load(x);unity(e);cdj_effect(e.p,0,1,.8);cdj_play(e.p,0,true);auto a=render(e.p,5000);check(std::abs(a.l[1000])>.05,"dry impulse");check(std::abs(a.l[4000])>.05,"375ms echo");near(a.l[3900],0,.0001,"not early echo");}});
    tests.push_back({"pattern_recording_exact_capture",[]{Mixer e;cdj_pattern(e.p,true,120,.5);check(cdj_record_begin(e.p),"record begin");auto out=render(e.p,8000);cdj_record_end(e.p);std::vector<float>x(16000);auto n=cdj_record_drain(e.p,x.data(),8000);check(n==8000&&cdj_record_dropped(e.p)==0,"record count");check(rms(out.l)>.01,"pattern nonzero");for(size_t i=0;i<n;++i)check(x[i*2]==out.l[i]&&x[i*2+1]==out.r[i],"exact ring sample");}});
    tests.push_back({"four_decks_and_natural_end",[]{Mixer e;for(int d=0;d<4;++d){e.load(tone(80+d*35,1),d);cdj_play(e.p,d,true);}auto a=render(e.p,10000);finiteAudio(a);check(rms(a.l)>.01,"four-deck mix");for(int d=0;d<4;++d){check(!cdj_is_playing(e.p,d),"stopped at end");near(cdj_position(e.p,d),1,.0001,"end position");}}});
    tests.push_back({"concurrent_load_hazard_reclamation",[]{Mixer e;auto x=tone(100,1);e.load(x);std::thread audio([&]{for(int i=0;i<1000;++i){cdj_play(e.p,0,true);render(e.p,128);}});for(int i=0;i<1000;++i){e.load(x);cdj_reclaim(e.p);}audio.join();cdj_reclaim(e.p);check(std::isfinite(cdj_position(e.p,0)),"finite concurrent position");}});
    tests.push_back({"recording_overflow_is_bounded_and_reported",[]{Mixer e;cdj_pattern(e.p,true,128,.3);check(cdj_record_begin(e.p),"begin overflow");auto output=render(e.p,(1u<<19)+1024);finiteAudio(output);cdj_record_end(e.p);check(cdj_record_dropped(e.p)==1024,"exact overflow count");std::vector<float>x((1u<<19)*2);auto n=cdj_record_drain(e.p,x.data(),1u<<19);check(n==(1u<<19),"fixed ring capacity");near(x[0],output.l[0],0,"ring first");near(x[(n-1)*2],output.l[n-1],0,"ring last");check(cdj_record_drain(e.p,x.data(),1)==0,"fully drained");}});
    tests.push_back({"invalid_controls_and_nonfinite_input",[]{Mixer e;auto x=tone(100,1);x[0]=NAN;x[1]=INFINITY;e.load(x);cdj_rate(e.p,0,NAN);cdj_eq(e.p,0,NAN,INFINITY,-INFINITY);cdj_filter(e.p,0,NAN);cdj_crossfader(e.p,NAN);cdj_master(e.p,NAN);cdj_seek(e.p,0,NAN);cdj_play(e.p,-1,true);cdj_play(e.p,9,true);cdj_play(e.p,0,true);finiteAudio(render(e.p,1000));check(!cdj_load(e.p,9,x.data(),8000,8000),"invalid deck rejected");}});
    tests.push_back({"effects_reverb_flanger_are_finite_and_change_signal",[]{for(int k=2;k<=3;++k){Mixer dry,wet;auto x=tone(220);dry.load(x);wet.load(x);unity(dry);unity(wet);cdj_effect(wet.p,0,k,.8);cdj_play(dry.p,0,true);cdj_play(wet.p,0,true);auto a=render(dry.p,16000),b=render(wet.p,16000);finiteAudio(b);double delta=0;for(size_t i=2000;i<a.l.size();++i)delta+=std::abs(a.l[i]-b.l[i]);check(delta>1,"effect changes samples");}}});
    double perfSeconds=0,perfAudioSeconds=10;float offlinePeak=0;std::string wavPath=argc>2?argv[2]:"";
    tests.push_back({"offline_ten_seconds_four_deck_render",[&]{Mixer e(48000);for(int d=0;d<4;++d){e.load(tone(100+d*70,1,48000),d,48000);cdj_loop(e.p,d,0,1,true);cdj_effect(e.p,d,d%4,.3);cdj_play(e.p,d,true);}Audio result(480000);auto begin=std::chrono::steady_clock::now();for(uint32_t at=0;at<480000;at+=512){auto n=std::min(512u,480000-at);insideRender=true;cdj_render(e.p,result.l.data()+at,result.r.data()+at,n);insideRender=false;}perfSeconds=std::chrono::duration<double>(std::chrono::steady_clock::now()-begin).count();finiteAudio(result);check(rms(result.l)>.01,"offline mix audible");for(float x:result.l)offlinePeak=std::max(offlinePeak,std::abs(x));if(!wavPath.empty())wav(wavPath,result,48000);}});
    struct Result{std::string name,error;double seconds;};std::vector<Result> results;
    int failures=0;
    for(auto &test:tests){auto begin=std::chrono::steady_clock::now();std::string error;try{test.second();}catch(const std::exception&ex){insideRender=false;error=ex.what();++failures;}results.push_back({test.first,error,std::chrono::duration<double>(std::chrono::steady_clock::now()-begin).count()});std::cerr<<(error.empty()?"PASS ":"FAIL ")<<test.first<<(error.empty()?"":" — "+error)<<"\n";}
    if(renderAllocations||renderFrees){++failures;std::cerr<<"FAIL render allocation guard\n";}
    std::ofstream file;if(argc>1)file.open(argv[1]);std::ostream&out=file.is_open()?file:std::cout;
    out<<"{\n  \"suite\":\"Contour standalone C++ DSP\",\n  \"test_count\":"<<results.size()<<",\n  \"failure_count\":"<<failures<<",\n  \"render_cpp_allocations\":"<<renderAllocations<<",\n  \"render_cpp_deallocations\":"<<renderFrees<<",\n  \"offline_audio_seconds\":"<<perfAudioSeconds<<",\n  \"offline_render_wall_seconds\":"<<perfSeconds<<",\n  \"offline_realtime_ratio\":"<<perfSeconds/perfAudioSeconds<<",\n  \"offline_peak\":"<<offlinePeak<<",\n  \"offline_wav\":\""<<escaped(wavPath)<<"\",\n  \"limitations\":[\"C++ allocator instrumentation does not interpose every libc allocator.\",\"CPU timing is one offline synthetic run, not device latency or dropout certification.\",\"AVAudioEngine output and file decoder are integration tests outside this core suite.\"],\n  \"tests\":[\n";
    for(size_t i=0;i<results.size();++i){auto &r=results[i];out<<"    {\"name\":\""<<escaped(r.name)<<"\",\"passed\":"<<(r.error.empty()?"true":"false")<<",\"seconds\":"<<r.seconds<<",\"error\":\""<<escaped(r.error)<<"\"}"<<(i+1<results.size()?",":"")<<"\n";}out<<"  ]\n}\n";
    return failures?1:0;
}
