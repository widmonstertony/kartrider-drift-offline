#include "Scene.hpp"
#include <algorithm>

namespace drift {
static V3 add(V3 a,V3 b){return{a.x+b.x,a.y+b.y,a.z+b.z};}
static V3 sub(V3 a,V3 b){return{a.x-b.x,a.y-b.y,a.z-b.z};}
static V3 mul(V3 a,float n){return{a.x*n,a.y*n,a.z*n};}
static float dot3(V3 a,V3 b){return a.x*b.x+a.y*b.y+a.z*b.z;}
static V3 cross(V3 a,V3 b){return{a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x};}
static V3 norm(V3 a){return mul(a,1/std::sqrt(std::max(.00001f,dot3(a,a))));}
static Matrix multiply(Matrix a,Matrix b){
    Matrix out{};for(int c=0;c<4;c++)for(int r=0;r<4;r++)for(int k=0;k<4;k++)out.m[c*4+r]+=a.m[k*4+r]*b.m[c*4+k];return out;
}
static Matrix camera(V3 eye,V3 target,float aspect){
    V3 back=norm(sub(eye,target)),side=norm(cross({0,1,0},back)),up=cross(back,side);
    Matrix view{{side.x,up.x,back.x,0,side.y,up.y,back.y,0,side.z,up.z,back.z,0,-dot3(side,eye),-dot3(up,eye),-dot3(back,eye),1}};
    float near=.2f,far=1100,f=1/std::tan(.52f);
    Matrix projection{{f/aspect,0,0,0,0,f,0,0,0,0,far/(near-far),-1,0,0,near*far/(near-far),0}};
    return multiply(projection,view);
}
class Builder {
public:
    std::vector<Vertex> out;
    void tri(V3 a,V3 b,V3 c,V3 color){
        V3 n=norm(cross(sub(b,a),sub(c,a)));
        for(auto p:{a,b,c})out.push_back({{p.x,p.y,p.z,1},{n.x,n.y,n.z,0},{color.x,color.y,color.z,1}});
    }
    void quad(V3 a,V3 b,V3 c,V3 d,V3 color){tri(a,b,c,color);tri(a,c,d,color);}
    void box(V3 p,V3 size,V3 color,float heading=0){
        V3 v[8];float s=std::sin(heading),c=std::cos(heading);
        for(int i=0;i<8;i++){float x=(i&1?.5f:-.5f)*size.x,y=(i&2?.5f:-.5f)*size.y,z=(i&4?.5f:-.5f)*size.z;v[i]={p.x+x*c+z*s,p.y+y,p.z-x*s+z*c};}
        quad(v[0],v[4],v[6],v[2],color);quad(v[1],v[3],v[7],v[5],color);
        quad(v[2],v[6],v[7],v[3],color);quad(v[0],v[1],v[5],v[4],color);
        quad(v[4],v[5],v[7],v[6],color);quad(v[0],v[2],v[3],v[1],color);
    }
    void octa(V3 p,float r,V3 color){
        V3 top=add(p,{0,r,0}),bottom=add(p,{0,-r,0});
        for(int i=0;i<4;i++){float a=i*pi/2,b=(i+1)*pi/2;V3 u=add(p,{std::sin(a)*r,0,std::cos(a)*r}),v=add(p,{std::sin(b)*r,0,std::cos(b)*r});tri(top,u,v,color);tri(bottom,v,u,color);}
    }
};
Frame makeFrame(const Game& game,float aspect){
    Builder b;b.out.reserve(22000);auto& track=game.track;auto& player=game.karts.front();
    V2 f=forward(player.heading);
    float speed=length(player.v),distance=10+speed*.035f;
    Frame frame;frame.viewProjection=camera({player.p.x-f.x*distance,6.8f,player.p.z-f.z*distance},{player.p.x+f.x*9,1,player.p.z+f.z*9},std::max(.2f,aspect));
    b.quad({-600,-.12f,-600},{-600,-.12f,700},{700,-.12f,700},{700,-.12f,-600},{.20f,.48f,.28f});
    for(size_t i=0;i<track.points.size();i++){
        auto a=track.points[i],c=track.points[(i+1)%track.points.size()];
        V2 ar={a.tangent.z,-a.tangent.x},cr={c.tangent.z,-c.tangent.x};
        auto point=[](V2 p,float y){return V3{p.x,y,p.z};};
        float w=track.width*.5f;
        b.quad(point(a.p-ar*w,0),point(c.p-cr*w,0),point(c.p+cr*w,0),point(a.p+ar*w,0),{.15f,.18f,.22f});
        V3 curb=i%4<2?V3{.95f,.24f,.18f}:V3{.92f,.93f,.89f};
        for(float sign:{-1.f,1.f}){
            b.quad(point(a.p+ar*(w*sign),.06f),point(c.p+cr*(w*sign),.06f),point(c.p+cr*((w+1)*sign),.06f),point(a.p+ar*((w+1)*sign),.06f),curb);
            if(i%3==0)b.box(point(a.p+ar*((w+2)*sign),.65f),{.4f,1.3f,.4f},{.72f,.80f,.85f});
        }
        if(i%5<2)b.quad(point(a.p-ar*.10f,.012f),point(c.p-cr*.10f,.012f),point(c.p+cr*.10f,.012f),point(a.p+ar*.10f,.012f),{.7f,.76f,.77f});
        if(i%8==0){
            V2 tree=a.p+ar*(w+10+(i%3)*4);b.box(point(tree,1.8f),{.8f,3.6f,.8f},{.40f,.25f,.12f});b.octa(point(tree,5),3.2f,{.11f,.36f,.20f});
        }
    }
    auto start=track.sample(track.start);V2 side={start.tangent.z,-start.tangent.x};float h=std::atan2(start.tangent.x,start.tangent.z);
    for(int row=0;row<2;row++)for(int col=0;col<12;col++){
        V2 p=start.p+side*((col-5.5f)*track.width/12)+start.tangent*(row*.8f);
        b.box({p.x,.018f,p.z},{track.width/12,.025f,.8f},(col+row)%2?V3{.95f,.95f,.95f}:V3{.03f,.04f,.06f},h);
    }
    for(float sign:{-1.f,1.f}){V2 p=start.p+side*(sign*(track.width*.5f+1));b.box({p.x,5,p.z},{.8f,10,.8f},{.12f,.25f,.45f},h);}
    b.box({start.p.x,10,start.p.z},{track.width+3,1.4f,1},{.12f,.45f,.8f},h);
    if(game.mode==Mode::Item)for(float s=0;s<track.totalLength;s+=95){
        auto t=track.sample(s+2);V2 r={t.tangent.z,-t.tangent.x};
        for(int lane=-1;lane<=1;lane++){V2 p=t.p+r*(lane*5.f);b.octa({p.x,1.7f,p.z},1.3f,{.98f,.72f,.12f});}
    }
    const V3 colors[]={{.12f,.67f,1},{1,.25f,.20f},{.98f,.70f,.16f},{.60f,.34f,.95f},{.18f,.85f,.52f},{.98f,.43f,.75f},{.88f,.90f,.94f},{.30f,.35f,.45f}};
    for(auto& k:game.karts){
        V3 color=colors[k.id%8];auto local=[&](float x,float y,float z){V2 p=k.p+right(k.heading)*x+forward(k.heading)*z;return V3{p.x,y,p.z};};
        b.box(local(0,.55f,0),{2.2f,.65f,3.2f},color,k.heading);
        b.box(local(0,.95f,1),{1.4f,.55f,1},color,k.heading);
        b.box(local(0,1.3f,-.35f),{.95f,.8f,.8f},{.18f,.22f,.30f},k.heading);
        b.octa(local(0,2.0f,-.35f),.64f,k.id==0?V3{1,.95f,.8f}:color);
        b.box(local(0,2.0f,.08f),{.82f,.24f,.08f},{.05f,.10f,.17f},k.heading);
        for(float x:{-1.1f,1.1f})for(float z:{-1.f,1.f})b.box(local(x,.40f,z),{.55f,.75f,.80f},{.035f,.045f,.055f},k.heading);
        b.box(local(0,.85f,-1.65f),{2.4f,.18f,.5f},color,k.heading);
        if(k.boost>0){b.octa(local(-.55f,.55f,-2.1f),.7f,{.15f,.85f,1});b.octa(local(.55f,.55f,-2.1f),.7f,{.15f,.85f,1});}
        if(k.shield>0)for(int i=0;i<12;i++){float a=i*pi/6;b.octa(local(std::sin(a)*1.9f,1,std::cos(a)*1.9f),.2f,{.3f,.9f,1});}
        if(k.stun>0)b.octa(local(0,3,0),.6f,{1,.95f,.1f});
        if(k.drifting)for(float x:{-1.f,1.f})b.octa(local(x,.18f,-1.5f),.3f,{1,.65f,.1f});
    }
    for(auto& v:game.hazards)b.octa({v.p.x,.7f,v.p.z},v.kind==Item::Banana?.65f:1,v.kind==Item::Banana?V3{1,.85f,.15f}:v.kind==Item::Rocket?V3{1,.3f,.15f}:V3{.1f,.6f,1});
    frame.vertices=std::move(b.out);return frame;
}
}
