#include "Game.hpp"
#include <algorithm>
#include <fstream>
#include <iomanip>
#include <sstream>

namespace drift {
static V2 catmull(V2 a,V2 b,V2 c,V2 d,float t){
    return (b*2+(c-a)*t+(a*2-b*5+c*4-d)*(t*t)+(b*3-a-c*3+d)*(t*t*t))*.5f;
}
Track::Track(){rebuild({{0,0},{95,0},{150,55},{150,120},{95,175},{20,200},{-75,180},{-130,120},{-110,45},{-55,15}});}
void Track::rebuild(const std::vector<V2>& c){
    points.clear();totalLength=0;
    int n=(int)c.size();
    for(int i=0;i<n;i++)for(int j=0;j<24;j++){
        V2 p=catmull(c[(i+n-1)%n],c[i],c[(i+1)%n],c[(i+2)%n],j/24.f);
        if(!points.empty())totalLength+=length(p-points.back().p);
        points.push_back({p,{},totalLength});
    }
    totalLength+=length(points.front().p-points.back().p);
    for(size_t i=0;i<points.size();i++)points[i].tangent=normalized(points[(i+1)%points.size()].p-points[(i+points.size()-1)%points.size()].p);
}
TrackPoint Track::sample(float s)const{
    s=std::fmod(s,totalLength);if(s<0)s+=totalLength;
    auto it=std::upper_bound(points.begin(),points.end(),s,[](float n,const TrackPoint& p){return n<p.s;});
    size_t i=it==points.begin()?0:size_t(it-points.begin()-1),j=(i+1)%points.size();
    float span=j?points[j].s-points[i].s:totalLength-points[i].s;
    float t=clamp((s-points[i].s)/span,0,1);
    return {points[i].p*(1-t)+points[j].p*t,normalized(points[i].tangent*(1-t)+points[j].tangent*t),s};
}
Projection Track::project(V2 p)const{
    Projection out;float best=1e30f;
    for(size_t i=0;i<points.size();i++){
        size_t j=(i+1)%points.size();V2 d=points[j].p-points[i].p;
        float t=clamp(dot(p-points[i].p,d)/std::fmax(dot(d,d),.001f),0,1);
        V2 q=points[i].p+d*t;float sq=dot(p-q,p-q);
        if(sq<best){
            best=sq;out.p=q;out.tangent=normalized(d);out.s=points[i].s+length(d)*t;
            out.lateral=dot(p-q,{out.tangent.z,-out.tangent.x});
        }
    }
    out.distance=std::sqrt(best);return out;
}
bool Track::loadCenterline(const std::string& path){
    std::ifstream f(path);std::string magic;int count=0;float w=0;
    if(!(f>>magic>>w>>count)||magic!="KDRIFT_TRACK_1"||count<4||count>10000||w<8||w>100)return false;
    std::vector<V2> c(count);
    for(auto& p:c)if(!(f>>p.x>>p.z)||!std::isfinite(p.x)||!std::isfinite(p.z))return false;
    for(int i=0;i<count;i++)if(length(c[i]-c[(i+1)%count])<1)return false;
    width=w;rebuild(c);return true;
}
Game::Game(uint32_t seed):rng(seed){start(Mode::Speed);}
void Game::start(Mode selected,int opponents){
    mode=selected;phase=Phase::Countdown;countdown=3;elapsed=0;remainder=0;paused=false;
    targetLaps=3;hazards.clear();events.clear();stats={};karts.clear();
    int count=mode==Mode::Practice?1:std::max(1,std::min(opponents+1,12));
    for(int i=0;i<count;i++){
        Kart k;k.id=i;k.ai=i!=0;
        float s=track.start-(i/2)*5.f;auto t=track.sample(s);
        V2 side={t.tangent.z,-t.tangent.x};
        k.p=t.p+side*((i%2?1.f:-1.f)*2.5f);k.heading=std::atan2(t.tangent.x,t.tangent.z);
        k.raceDistance=-(i/2)*5.f;k.lastS=track.project(k.p).s;k.itemCooldown=1+i*.25f;
        k.aiCooldown=1+(rng()%100)*.02f;karts.push_back(k);
    }
    updateRanking();
}
Input Game::aiInput(Kart& k,float dt){
    Input in;auto near=track.project(k.p);float speed=length(k.v);
    float lane=std::sin(float(k.id)*2.3f)*3.f;
    auto ahead=track.sample(near.s+14+speed*.40f);
    V2 target=ahead.p+V2{ahead.tangent.z,-ahead.tangent.x}*lane;
    V2 delta=target-k.p;float desired=std::atan2(delta.x,delta.z);
    float angle=wrap(desired-k.heading);
    auto far=track.sample(near.s+35+speed*.5f);
    float bend=std::fabs(wrap(std::atan2(far.tangent.x,far.tangent.z)-std::atan2(near.tangent.x,near.tangent.z)));
    float wanted=49.f/(1+bend*.85f);
    in.steer=clamp(angle*1.65f-k.yaw*.12f,-1,1);
    in.throttle=speed>wanted+3?.25f:1.f;in.brake=speed>wanted+7?.65f:0;
    in.drift=(std::fabs(angle)>.36f||bend>.45f)&&speed>27&&near.distance<track.width*.30f;
    k.aiCooldown-=dt;
    if(k.aiCooldown<=0){
        bool straight=bend<.32f;
        in.use=(mode==Mode::Item&&k.item!=Item::None&&(k.item!=Item::Boost||straight))||(mode!=Mode::Item&&k.nitros>0&&straight);
        if(in.use)k.aiCooldown=1.2f+(rng()%100)*.025f;
    }
    return in;
}
void Game::tick(float seconds,const Input& player){
    events.clear();if(paused)return;
    remainder+=clamp(seconds,0,.15f);
    constexpr float dt=1.f/120.f;
    while(remainder>=dt){step(dt,player);remainder-=dt;}
}
void Game::step(float dt,const Input& player){
    if(phase==Phase::Countdown){countdown-=dt;if(countdown<=0){phase=Phase::Racing;countdown=0;}return;}
    elapsed+=dt;
    for(auto& k:karts){
        Input in=(k.ai||autopilot||k.finished)?aiInput(k,dt):player;
        drive(k,in,dt);
    }
    for(size_t a=0;a<karts.size();a++)for(size_t b=a+1;b<karts.size();b++){
        auto& x=karts[a];auto& y=karts[b];V2 delta=y.p-x.p;float d=length(delta);
        if(d<2.75f){
            V2 normal=d>.001f?delta/d:V2{1,0};float overlap=2.75f-d;
            x.p+=normal*(-overlap*.5f);y.p+=normal*(overlap*.5f);
            float closing=dot(y.v-x.v,normal);
            if(closing<0){float impulse=-closing*.62f;x.v+=normal*(-impulse);y.v+=normal*impulse;}
        }
    }
    updateHazards(dt);updateRanking();
    if(mode!=Mode::Practice&&karts.front().finished)phase=Phase::Finished;
}
void Game::drive(Kart& k,const Input& in,float dt){
    k.boost=std::fmax(0,k.boost-dt);k.shield=std::fmax(0,k.shield-dt);
    k.stun=std::fmax(0,k.stun-dt);k.slow=std::fmax(0,k.slow-dt);
    k.itemCooldown=std::fmax(0,k.itemCooldown-dt);
    if(in.use&&!k.useWasDown&&!k.finished)useItem(k);k.useWasDown=in.use;
    float speed=length(k.v),forwardSpeed=dot(k.v,forward(k.heading));
    k.drifting=in.drift&&speed>10&&k.stun<=0;
    float steer=clamp(in.steer,-1,1);
    float authority=clamp(std::fabs(forwardSpeed)/20,0,1.7f);
    float targetYaw=steer*authority*(k.drifting?1.65f:1.4f)/(1+speed*.012f);
    if(k.stun>0)targetYaw=0;
    k.yaw+=(targetYaw-k.yaw)*(1-std::exp(-(k.drifting?5.f:9.f)*dt));
    k.heading=wrap(k.heading+k.yaw*dt);
    V2 f=forward(k.heading),r=right(k.heading);
    float lateral=dot(k.v,r);float grip=k.drifting?1.65f:11.f;
    k.v+=r*(-lateral*std::fmin(grip*dt,1.f));
    float throttle=clamp(in.throttle,0,1);if(k.stun>0)throttle=0;
    float accel=throttle*(k.boost>0?34.f:18.f);
    if(k.slow>0)accel*=.45f;
    k.v+=f*(accel*dt);
    float resistance=(.8f+speed*speed*.006f+clamp(in.brake,0,1)*23.f+(k.stun>0?30.f:0)+(k.slow>0?12.f:0))*dt;
    float now=length(k.v);k.v=k.v*(std::fmax(0,now-resistance)/std::fmax(now,.0001f));
    float limit=k.boost>0?76.f:58.f;if(length(k.v)>limit)k.v=normalized(k.v)*limit;
    k.p+=k.v*dt;
    auto projected=track.project(k.p);
    float edge=track.width*.5f-1.5f;
    if(projected.distance>edge){
        V2 outward=normalized(k.p-projected.p);k.p=projected.p+outward*edge;
        float outwardSpeed=dot(k.v,outward);if(outwardSpeed>0)k.v+=outward*(-outwardSpeed*1.35f);
        k.v=k.v*(1-dt*.75f);
    }
    if(k.drifting){
        stats.driftSeconds+=dt;
        k.driftDuration+=dt;
        k.gauge+=dt*clamp((std::fabs(lateral)+std::fabs(k.yaw)*4)*.025f,0,.65f);
        if(k.gauge>=1){k.gauge-=1;k.nitros=std::min(2,k.nitros+1);}
    }else k.driftDuration=0;
    float delta=projected.s-k.lastS;
    if(delta>track.totalLength*.5f)delta-=track.totalLength;
    if(delta<-track.totalLength*.5f)delta+=track.totalLength;
    if(std::fabs(delta)<12)k.raceDistance+=delta;
    k.lastS=projected.s;k.lap=std::max(0,(int)std::floor(k.raceDistance/track.totalLength));
    if(mode==Mode::Item&&k.item==Item::None&&k.itemCooldown<=0){
        // Item boxes are deterministic lanes repeated around the course.
        float zone=std::fmod(projected.s+track.totalLength,95.f);
        if(zone<4){k.item=Item(1+rng()%6);k.itemCooldown=2.5f;events.push_back({Event::Pickup,k.id});}
    }
    if(mode!=Mode::Practice&&!k.finished&&k.raceDistance>=track.totalLength*targetLaps){
        k.finished=true;k.finishTime=elapsed;events.push_back({Event::Finish,k.id});
    }
    if(k.ai||autopilot){
        if(k.raceDistance-k.lastAdvance<.3f)k.stuckTime+=dt;else{k.stuckTime=0;k.lastAdvance=k.raceDistance;}
        if(k.stuckTime>4&&!k.finished)rescue(k.id);
    }
}
void Game::useItem(Kart& k){
    if(mode!=Mode::Item){
        if(k.nitros<=0||k.boost>0)return;
        k.nitros--;k.boost=2.4f;stats.boosts++;events.push_back({Event::Boost,k.id});return;
    }
    if(k.item==Item::None)return;
    Item item=k.item;k.item=Item::None;stats.itemsUsed++;events.push_back({Event::Fire,k.id});
    if(item==Item::Boost){k.boost=2.5f;stats.boosts++;}
    else if(item==Item::Shield)k.shield=4;
    else if(item==Item::Lightning){
        for(auto& target:karts)if(target.id!=k.id&&target.raceDistance>k.raceDistance)hit(target,1.4f,k.id);
    }else if(item==Item::Banana){
        hazards.push_back({k.p-forward(k.heading)*4,{},18,0,k.id,-1,item});
    }else if(item==Item::WaterBomb){
        hazards.push_back({k.p,forward(k.heading)*30.f,1,0,k.id,-1,item});
    }else if(item==Item::Rocket){
        int target=-1;float best=90;
        for(auto& other:karts){
            V2 d=other.p-k.p;float distance=length(d);
            if(other.id!=k.id&&distance<best&&dot(normalized(d),forward(k.heading))>.1f){best=distance;target=other.id;}
        }
        hazards.push_back({k.p+forward(k.heading)*3,forward(k.heading)*65,3,0,k.id,target,item});
    }
}
void Game::hit(Kart& k,float seconds,int owner){
    if(k.shield>0){k.shield=0;return;}
    k.stun=seconds;k.boost=0;k.v=k.v*.55f;stats.hits++;events.push_back({Event::Hit,k.id});
    (void)owner;
}
void Game::updateHazards(float dt){
    for(auto& h:hazards){
        h.age+=dt;h.ttl-=dt;
        if(h.kind==Item::Rocket&&h.target>=0&&h.target<(int)karts.size()){
            V2 desired=normalized(karts[h.target].p-h.p)*65;
            h.v=normalized(h.v*(1-dt*3)+desired*(dt*3))*65;
        }
        h.p+=h.v*dt;
        if(h.kind==Item::WaterBomb){
            if(h.ttl<=0)for(auto& k:karts)if(k.id!=h.owner&&length(k.p-h.p)<12)hit(k,1.25f,h.owner);
        }else for(auto& k:karts){
            if(k.id==h.owner||h.ttl<=0)continue;
            if(length(k.p-h.p)<(h.kind==Item::Rocket?2.7f:2.2f)){hit(k,h.kind==Item::Rocket?1.f:1.3f,h.owner);h.ttl=0;}
        }
    }
    hazards.erase(std::remove_if(hazards.begin(),hazards.end(),[](const Hazard& h){return h.ttl<=0;}),hazards.end());
}
void Game::updateRanking(){
    for(auto& k:karts){
        k.place=1;
        for(auto& other:karts)if(other.id!=k.id){
            if(other.finished&&(!k.finished||other.finishTime<k.finishTime))k.place++;
            else if(!other.finished&&!k.finished&&other.raceDistance>k.raceDistance)k.place++;
        }
    }
}
void Game::rescue(int index){
    if(index<0||index>=(int)karts.size())return;
    auto& k=karts[index];auto t=track.sample(k.lastS+3);
    k.p=t.p;k.heading=std::atan2(t.tangent.x,t.tangent.z);k.v=t.tangent*12;
    k.yaw=0;k.stun=0;k.lastS=t.s;k.stuckTime=0;k.lastAdvance=k.raceDistance;stats.rescues++;
}
const char* Game::itemName(Item i){
    switch(i){case Item::Boost:return "加速";case Item::Rocket:return "火箭";case Item::Banana:return "香蕉";case Item::Shield:return "护盾";case Item::Lightning:return "闪电";case Item::WaterBomb:return "水弹";default:return "空";}
}
std::string Game::hud()const{
    auto& k=karts.front();std::ostringstream s;
    s<<(mode==Mode::Speed?"竞速赛":mode==Mode::Item?"道具赛":"单人练习")<<"  ·  本地离线\n";
    if(phase==Phase::Countdown)s<<"准备 "<<std::max(1,(int)std::ceil(countdown));
    else if(k.finished)s<<"完成！第 "<<k.place<<" 名";
    else s<<"第 "<<k.place<<" / "<<karts.size()<<" 名";
    s<<"    圈 "<<std::min(targetLaps,k.lap+1)<<" / "<<targetLaps;
    s<<"    "<<(int)(length(k.v)*3.6f)<<" km/h\n";
    s<<std::fixed<<std::setprecision(1)<<(k.finished?k.finishTime:elapsed)<<" s    ";
    if(mode==Mode::Item)s<<"道具："<<itemName(k.item);
    else s<<"氮气 "<<k.nitros<<"    漂移集气 "<<(int)(k.gauge*100)<<"%";
    if(paused)s<<"    已暂停";
    return s.str();
}
}
