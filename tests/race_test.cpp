#include "Game.hpp"
#include <cassert>
#include <iostream>

int main(){
    using namespace drift;
    for(unsigned seed:{1u,42u,1234u})for(Mode mode:{Mode::Speed,Mode::Item}){
        Game game(seed);game.start(mode);game.autopilot=true;
        for(int i=0;i<120*200;i++){
            game.tick(1.f/120,{});
            for(auto& k:game.karts){assert(std::isfinite(k.p.x));assert(std::isfinite(k.p.z));assert(length(k.v)<100);}
            bool done=true;for(auto& k:game.karts)done=done&&k.finished;
            if(done)break;
        }
        int finished=0;for(auto& k:game.karts)finished+=k.finished;
        std::cout<<(mode==Mode::Speed?"speed":"item")<<" seed="<<seed<<" finished="<<finished<<"/8 items="<<game.stats.itemsUsed<<" hits="<<game.stats.hits<<" boosts="<<game.stats.boosts<<" drift="<<game.stats.driftSeconds<<" rescues="<<game.stats.rescues<<"\n";
        assert(finished==8);
        assert(game.stats.driftSeconds>10);
        for(auto& k:game.karts){assert(k.finishTime>0);assert(k.place>=1&&k.place<=8);for(auto& other:game.karts)if(k.id!=other.id)assert(k.place!=other.place);}
        if(mode==Mode::Item){assert(game.stats.itemsUsed>8);assert(game.stats.hits>0);}
    }
    Game game;game.start(Mode::Practice);assert(game.karts.size()==1);
    game.paused=true;float countdown=game.countdown;game.tick(1,{});assert(game.countdown==countdown);
    game.paused=false;game.tick(.1f,{});assert(game.countdown<countdown);
    game.phase=Phase::Racing;game.karts[0].v=forward(game.karts[0].heading)*40;
    V2 before=game.karts[0].p;Input input;input.steer=.65f;input.drift=true;
    for(int i=0;i<120;i++)game.tick(1.f/120,input);
    assert(length(game.karts[0].p-before)>10);assert(game.karts[0].gauge>.05f);assert(game.stats.driftSeconds>.9f);
    input={};input.use=true;game.tick(1.f/60,input);assert(game.karts[0].boost>2);assert(game.karts[0].nitros==0);
    // Shield must consume an attack without stunning its holder.
    Game items;items.start(Mode::Item,1);items.phase=Phase::Racing;
    items.karts[0].item=Item::Lightning;items.karts[1].shield=2;items.karts[1].raceDistance=10;
    items.tick(1.f/60,input);assert(items.stats.itemsUsed==1);assert(items.karts[1].shield==0);assert(items.karts[1].stun==0);
    std::cout<<"Offline race integration checks passed\n";
}
