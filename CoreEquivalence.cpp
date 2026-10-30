#include "CDJCore.h"
#include <cmath>
#include <cstdint>
#include <fstream>
#include <vector>

// Independent long state-transition trace: compare this executable linked to
// frozen baseline versus current core, including transport state after blocks.
int main(int argc,char**argv){
    if(argc!=2)return 2;
    std::ofstream f(argv[1],std::ios::binary);if(!f)return 2;
    auto e=cdj_create(48000);if(!e)return 2;
    std::vector<float>pcm(96000),left(4096),right(4096),record(8192);
    for(size_t i=0;i<48000;++i){pcm[i*2]=float(.17*std::sin(i*.019)+.06*std::cos(i*.47));pcm[i*2+1]=float(.13*std::cos(i*.023)+.04*std::sin(i*.19));}
    for(int d=0;d<4;++d){if(!cdj_load(e,d,pcm.data(),48000,48000))return 2;cdj_loop(e,d,.1,.9,true);}
    const uint32_t sizes[]{0,1,7,63,128,257,512,1024,4096};
    for(int step=0;step<2400;++step){
        const uint32_t frames=sizes[step%9];
        if(step==64||step==700||step==1300||step==2000)for(int d=0;d<4;++d)cdj_play(e,d,true);
        if(step==380||step==1000||step==1600)for(int d=0;d<4;++d)cdj_play(e,d,false);
        if(step%71==0){cdj_crossfader(e,(step%23)/22.0);cdj_master(e,.4+(step%17)/20.0);}
        if(step%89==0)for(int d=0;d<4;++d){cdj_volume(e,d,.1+(step%13)/15.0);cdj_rate(e,d,.6+(step%11)/10.0);cdj_eq(e,d,-24+(step%31),-8+(step%17),-12+(step%23));cdj_filter(e,d,(step%43)/21.0-1);cdj_effect(e,d,(step/89+d)%4,(step%19)/18.0);}
        if(step%113==0)for(int d=0;d<4;++d){cdj_reverse(e,d,(step/113+d)%2);cdj_seek(e,d,.1+(step%73)/100.0);}
        if(step%167==0)cdj_pattern(e,(step/167)%2,80+step%90,.35);
        if(step==800)cdj_record_begin(e);
        if(step==1200)cdj_record_end(e);
        if(step==1100){if(!cdj_load(e,2,pcm.data(),48000,48000))return 2;cdj_loop(e,2,.2,.8,true);}
        cdj_render(e,left.data(),right.data(),frames);
        f.write(reinterpret_cast<const char*>(left.data()),frames*sizeof(float));
        f.write(reinterpret_cast<const char*>(right.data()),frames*sizeof(float));
        float positions[8];for(int d=0;d<4;++d){positions[d]=float(cdj_position(e,d));positions[d+4]=cdj_is_playing(e,d)?1:0;}
        f.write(reinterpret_cast<const char*>(positions),sizeof(positions));
        if(step>=800&&step<=1200)cdj_record_drain(e,record.data(),frames);
    }
    cdj_destroy(e);return f?0:2;
}
