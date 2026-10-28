#include "Audio.hpp"

namespace drift {
void Audio::update(const Game& game){
    auto& k=game.karts.front();pitch.store(55+length(k.v)*3.3f+(k.boost>0?35:0),std::memory_order_relaxed);
    gain.store(game.paused?0:.045f+(game.phase==Phase::Countdown?.01f:.04f),std::memory_order_relaxed);
    slide.store(!game.paused&&k.drifting?.035f:0,std::memory_order_relaxed);
    for(auto e:game.events)if(e.kart==0)trigger.store(1+int(e.kind),std::memory_order_relaxed);
}
void Audio::render(float* stereo,int frames,float rate){
    float hz=pitch.load(std::memory_order_relaxed),volume=gain.load(std::memory_order_relaxed),skid=slide.load(std::memory_order_relaxed);
    int event=trigger.exchange(0,std::memory_order_relaxed);if(event){effect=event;effectTime=.25f;effectPhase=0;}
    for(int i=0;i<frames;i++){
        currentPitch+=(hz-currentPitch)*.0015f;currentGain+=(volume-currentGain)*.0015f;
        phase+=currentPitch/rate;if(phase>=1)phase-=1;
        noiseState=noiseState*1664525u+1013904223u;float noise=float(noiseState>>8)/8388607.5f-1;
        float sound=(std::sin(phase*2*pi)+.35f*std::sin(phase*4*pi)+.15f*std::sin(phase*8*pi))*currentGain+noise*skid;
        if(effectTime>0){
            effectTime-=1/rate;effectPhase+=(effect==3?160.f:effect==5?880.f:440.f+effectTime*1200)/rate;
            sound+=(effect==3?noise:std::sin(effectPhase*2*pi))*.35f*effectTime;
        }
        stereo[i*2]=sound;stereo[i*2+1]=sound;
    }
}
}
