#include "CDJCore.h"
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <fstream>
#include <functional>
#include <iomanip>
#include <iostream>
#include <new>
#include <string>
#include <vector>

thread_local bool inRender=false;
std::atomic<uint64_t> allocations{0},deallocations{0};
void* operator new(std::size_t n){if(inRender)++allocations;if(auto p=std::malloc(n?n:1))return p;throw std::bad_alloc();}
void* operator new[](std::size_t n){return ::operator new(n);}
void operator delete(void*p)noexcept{if(inRender&&p)++deallocations;std::free(p);}
void operator delete[](void*p)noexcept{::operator delete(p);}
void operator delete(void*p,std::size_t)noexcept{::operator delete(p);}
void operator delete[](void*p,std::size_t)noexcept{::operator delete(p);}

namespace {
using Clock=std::chrono::steady_clock;
constexpr double pi=3.14159265358979323846,sr=48000;
constexpr int repetitions=5,warmup=256,measured=2048;
struct Scenario{const char*name;int decks;bool fx,pattern,paused,tails,controls,reverse,record;};
const Scenario scenarios[]={
    {"idle_empty",0,false,false,false,false,false,false,false},
    {"paused_four_decks",4,false,false,true,false,false,false,false},
    {"two_decks_dry",2,false,false,false,false,false,false,false},
    {"four_decks_dry",4,false,false,false,false,false,false,false},
    {"four_decks_fx",4,true,false,false,false,false,false,false},
    {"pattern_only",0,false,true,false,false,false,false,false},
    {"four_decks_fx_pattern",4,true,true,false,false,false,false,false},
    {"paused_fx_tails",4,true,false,false,true,false,false,false},
    {"smoothed_controls",4,true,false,false,false,true,false,false},
    {"reverse_loops",4,true,false,false,false,false,true,false},
    {"four_decks_recording",4,true,true,false,false,false,false,true}
};
double percentile(std::vector<double> v,double p){std::sort(v.begin(),v.end());return v[std::min(v.size()-1,size_t(std::ceil(p*v.size())-1))];}
struct Metrics{double median,p95,p99,max;uint64_t misses;};
Metrics summarize(const std::vector<double>&v,double deadline){uint64_t miss=0;for(double n:v)miss+=n>deadline;return{percentile(v,.5),percentile(v,.95),percentile(v,.99),*std::max_element(v.begin(),v.end()),miss};}
void emit(std::ostream&o,const Metrics&m){o<<"{\"median_us\":"<<m.median<<",\"p95_us\":"<<m.p95<<",\"p99_us\":"<<m.p99<<",\"max_us\":"<<m.max<<",\"deadline_misses\":"<<m.misses<<"}";}
std::vector<float> audio(){std::vector<float>p(48000*2);for(size_t i=0;i<48000;++i){double t=i/sr;p[i*2]=float(.12*std::sin(2*pi*110*t)+.04*std::sin(2*pi*3700*t));p[i*2+1]=float(.1*std::sin(2*pi*173*t)+.035*std::cos(2*pi*2700*t));}return p;}
}
int main(int argc,char**argv){
    if(argc<3){std::cerr<<"usage: core-benchmark report.json golden.f32\n";return 2;}
    std::ofstream output(argv[1]),golden(argv[2],std::ios::binary);
    if(!output||!golden)return 2;
    auto pcm=audio();bool firstCase=true;uint64_t nonfinite=0;double checksum=0;float peak=0;
    output<<std::setprecision(10)<<"{\n\"sample_rate\":48000,\"repetitions\":"<<repetitions<<",\"warmup_callbacks_per_repeat\":"<<warmup<<",\"measured_callbacks_per_repeat\":"<<measured<<",\"compiler_flags\":\"clang++ C++17 -O3 -DNDEBUG, no fast-math\",\"method\":\"steady_clock around cdj_render only; fresh engine per repeat; fixed preallocated buffers; first16 measured callbacks captured per scenario/buffer\",\"cases\":[\n";
    for(auto&s:scenarios)for(uint32_t frames:{128u,256u,512u}){
        std::vector<double>all;all.reserve(repetitions*measured);
        std::vector<Metrics>runs;std::vector<float>l(frames),r(frames),record(frames*2);
        const double deadline=frames/sr*1e6;
        for(int repeat=0;repeat<repetitions;++repeat){
            CDJEngine*e=cdj_create(sr);if(!e)return 2;
            for(int d=0;d<s.decks;++d){if(!cdj_load(e,d,pcm.data(),48000,sr))return 2;cdj_loop(e,d,s.reverse?.2:0,s.reverse?.8:1,true);cdj_seek(e,d,s.reverse?.7:0);cdj_volume(e,d,.7);cdj_play(e,d,!s.paused);if(s.fx)cdj_effect(e,d,d%3+1,.45);if(s.reverse)cdj_reverse(e,d,true);}
            cdj_pattern(e,s.pattern,123,.35);
            for(int i=0;i<warmup;++i)cdj_render(e,l.data(),r.data(),frames);
            if(s.tails)for(int d=0;d<s.decks;++d)cdj_play(e,d,false);
            if(s.record)cdj_record_begin(e);
            std::vector<double>times(measured);
            for(int i=0;i<measured;++i){
                if(s.controls){cdj_crossfader(e,(i%67)/66.0);cdj_volume(e,0,.2+.6*(i%31)/30.0);cdj_rate(e,1,.85+.3*(i%53)/52.0);if(i%32==0){cdj_eq(e,2,-12+double(i%17),0,3);cdj_filter(e,3,(i%41)/20.0-1);}}
                auto begin=Clock::now();inRender=true;cdj_render(e,l.data(),r.data(),frames);inRender=false;auto end=Clock::now();
                times[i]=std::chrono::duration<double,std::micro>(end-begin).count();
                if(s.record)cdj_record_drain(e,record.data(),frames);
                for(uint32_t n=0;n<frames;++n){nonfinite+=!std::isfinite(l[n])||!std::isfinite(r[n]);peak=std::max(peak,std::max(std::abs(l[n]),std::abs(r[n])));}
                checksum+=l[i%frames]+r[(i*3)%frames];
                if(repeat==0&&i<16){golden.write(reinterpret_cast<char*>(l.data()),frames*sizeof(float));golden.write(reinterpret_cast<char*>(r.data()),frames*sizeof(float));}
            }
            if(s.record)cdj_record_end(e);
            cdj_destroy(e);runs.push_back(summarize(times,deadline));all.insert(all.end(),times.begin(),times.end());
        }
        auto total=summarize(all,deadline);
        if(!firstCase)output<<",\n";firstCase=false;
        output<<"{\"workload\":\""<<s.name<<"\",\"frames\":"<<frames<<",\"callback_deadline_us\":"<<deadline<<",\"sample_count\":"<<all.size()<<",\"summary\":";emit(output,total);output<<",\"repeats\":[";
        for(size_t i=0;i<runs.size();++i){if(i)output<<",";emit(output,runs[i]);}output<<"]}";
        std::cerr<<s.name<<"/"<<frames<<" median "<<total.median<<"us p99 "<<total.p99<<"us max "<<total.max<<"us\n";
    }
    output<<"\n],\"render_cpp_allocations\":"<<allocations<<",\"render_cpp_deallocations\":"<<deallocations<<",\"nonfinite_samples\":"<<nonfinite<<",\"peak\":"<<peak<<",\"checksum\":"<<checksum<<",\"limitations\":[\"Offline unscheduled timing excludes hardware, AVAudioEngine, UI, decode and output-buffer latency.\",\"No zero-lag or dropout-free live-playback claim.\",\"Global C++ new/delete instrumentation does not intercept every libc allocation.\"]}\n";
    return allocations||deallocations||nonfinite?1:0;
}
