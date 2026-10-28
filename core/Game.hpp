#pragma once
#include <array>
#include <cmath>
#include <cstdint>
#include <random>
#include <string>
#include <vector>

namespace drift {
constexpr float pi=3.14159265358979323846f;
struct V2 {
    float x=0,z=0;
    V2 operator+(V2 b)const{return{x+b.x,z+b.z};}
    V2 operator-(V2 b)const{return{x-b.x,z-b.z};}
    V2 operator*(float s)const{return{x*s,z*s};}
    V2 operator/(float s)const{return{x/s,z/s};}
    V2& operator+=(V2 b){x+=b.x;z+=b.z;return *this;}
};
inline float dot(V2 a,V2 b){return a.x*b.x+a.z*b.z;}
inline float length(V2 a){return std::sqrt(dot(a,a));}
inline V2 normalized(V2 a){float n=length(a);return n>0.0001f?a/n:V2{};}
inline float clamp(float x,float lo,float hi){return std::fmax(lo,std::fmin(hi,x));}
inline float wrap(float a){while(a>pi)a-=2*pi;while(a<-pi)a+=2*pi;return a;}
inline V2 forward(float h){return{std::sin(h),std::cos(h)};}
inline V2 right(float h){return{std::cos(h),-std::sin(h)};}

struct TrackPoint {V2 p,tangent;float s=0;};
struct Projection {V2 p,tangent;float s=0,lateral=0,distance=0;};
class Track {
public:
    std::vector<TrackPoint> points;
    float totalLength=0,width=22,start=18;
    Track();
    TrackPoint sample(float s)const;
    Projection project(V2 p)const;
    bool loadCenterline(const std::string& path);
private:
    void rebuild(const std::vector<V2>& controls);
};

enum class Mode {Speed,Item,Practice};
enum class Phase {Countdown,Racing,Finished};
enum class Item {None,Boost,Rocket,Banana,Shield,Lightning,WaterBomb};
struct Input {float steer=0,throttle=1,brake=0;bool drift=false,use=false;};
struct Kart {
    V2 p,v;
    float heading=0,yaw=0,boost=0,shield=0,stun=0,slow=0,gauge=0;
    float raceDistance=0,lastS=0,finishTime=-1,itemCooldown=0,aiCooldown=0;
    float stuckTime=0,lastAdvance=0,driftDuration=0;
    int id=0,nitros=1,lap=0,place=1;
    bool ai=false,finished=false,drifting=false,useWasDown=false;
    Item item=Item::None;
};
struct Hazard {V2 p,v;float ttl=0,age=0;int owner=0,target=-1;Item kind=Item::Banana;};
struct RaceStats {int itemsUsed=0,hits=0,boosts=0,rescues=0;float driftSeconds=0;};
struct Event {enum Kind{Boost,Fire,Hit,Pickup,Finish} kind;int kart;};

class Game {
public:
    Track track;
    std::vector<Kart> karts;
    std::vector<Hazard> hazards;
    std::vector<Event> events;
    RaceStats stats;
    Mode mode=Mode::Speed;
    Phase phase=Phase::Countdown;
    float countdown=3,elapsed=0;
    int targetLaps=3;
    bool paused=false,autopilot=false;
    explicit Game(uint32_t seed=0x4b445246);
    void start(Mode selected,int opponents=7);
    void tick(float seconds,const Input& player);
    void rescue(int index);
    std::string hud()const;
    static const char* itemName(Item item);
private:
    std::mt19937 rng;
    float remainder=0;
    Input aiInput(Kart& kart,float dt);
    void step(float dt,const Input& player);
    void drive(Kart& kart,const Input& in,float dt);
    void useItem(Kart& kart);
    void hit(Kart& kart,float seconds,int owner);
    void updateHazards(float dt);
    void updateRanking();
};
}
