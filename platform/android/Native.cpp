#include <jni.h>
#include <GLES3/gl3.h>
#include <android/log.h>
#include <aaudio/AAudio.h>
#include <chrono>
#include <memory>
#include "Game.hpp"
#include "Scene.hpp"
#include "Audio.hpp"

namespace {
std::unique_ptr<drift::Game> game;
drift::Audio sound;AAudioStream* audioStream=nullptr;
drift::Input controls;
GLuint program,vao,vbo;GLint matrix;
int width=1,height=1;
std::chrono::steady_clock::time_point previous;
aaudio_data_callback_result_t audioCallback(AAudioStream* stream,void*,void* data,int32_t frames){sound.render(static_cast<float*>(data),frames,float(AAudioStream_getSampleRate(stream)));return AAUDIO_CALLBACK_RESULT_CONTINUE;}
GLuint shader(GLenum kind,const char* source){
    GLuint s=glCreateShader(kind);glShaderSource(s,1,&source,nullptr);glCompileShader(s);
    GLint ok=0;glGetShaderiv(s,GL_COMPILE_STATUS,&ok);
    if(!ok){char message[2048];glGetShaderInfoLog(s,sizeof(message),nullptr,message);__android_log_print(ANDROID_LOG_ERROR,"KartDrift","%s",message);}
    return s;
}
}
extern "C" JNIEXPORT void JNICALL Java_org_kartdrift_offline_nativeapp_RaceActivity_nativeCreate(JNIEnv*,jclass){
    if(!game)game=std::make_unique<drift::Game>();
    if(!audioStream){AAudioStreamBuilder* builder=nullptr;AAudio_createStreamBuilder(&builder);AAudioStreamBuilder_setDirection(builder,AAUDIO_DIRECTION_OUTPUT);AAudioStreamBuilder_setFormat(builder,AAUDIO_FORMAT_PCM_FLOAT);AAudioStreamBuilder_setChannelCount(builder,2);AAudioStreamBuilder_setPerformanceMode(builder,AAUDIO_PERFORMANCE_MODE_LOW_LATENCY);AAudioStreamBuilder_setDataCallback(builder,audioCallback,nullptr);if(AAudioStreamBuilder_openStream(builder,&audioStream)==AAUDIO_OK)AAudioStream_requestStart(audioStream);AAudioStreamBuilder_delete(builder);}
    const char* vertex="#version 300 es\nprecision highp float;layout(location=0) in vec4 p;layout(location=1) in vec4 n;layout(location=2) in vec4 c;uniform mat4 m;out vec4 color;out float fog;void main(){vec4 clip=m*p;gl_Position=vec4(clip.xy,2.0*clip.z-clip.w,clip.w);float light=.48+.52*max(0.0,dot(n.xyz,normalize(vec3(-.4,1,.25))));color=vec4(c.rgb*light,1);fog=clamp((clip.w-110.0)/400.0,0.0,.85);}";
    const char* fragment="#version 300 es\nprecision mediump float;in vec4 color;in float fog;out vec4 outputColor;void main(){outputColor=mix(color,vec4(.48,.72,.9,1),fog);}";
    GLuint vs=shader(GL_VERTEX_SHADER,vertex),fs=shader(GL_FRAGMENT_SHADER,fragment);
    program=glCreateProgram();glAttachShader(program,vs);glAttachShader(program,fs);glLinkProgram(program);glDeleteShader(vs);glDeleteShader(fs);
    GLint ok;glGetProgramiv(program,GL_LINK_STATUS,&ok);if(!ok)__android_log_print(ANDROID_LOG_ERROR,"KartDrift","Program link failed");
    matrix=glGetUniformLocation(program,"m");glGenVertexArrays(1,&vao);glBindVertexArray(vao);glGenBuffers(1,&vbo);glBindBuffer(GL_ARRAY_BUFFER,vbo);
    for(int i=0;i<3;i++){glEnableVertexAttribArray(i);glVertexAttribPointer(i,4,GL_FLOAT,GL_FALSE,sizeof(drift::Vertex),reinterpret_cast<void*>(i*4*sizeof(float)));}
    glEnable(GL_DEPTH_TEST);glDepthFunc(GL_LESS);glClearColor(.48,.72,.9,1);previous=std::chrono::steady_clock::now();
}
extern "C" JNIEXPORT void JNICALL Java_org_kartdrift_offline_nativeapp_RaceActivity_nativeResize(JNIEnv*,jclass,jint w,jint h){width=w;height=h;glViewport(0,0,w,h);}
extern "C" JNIEXPORT jstring JNICALL Java_org_kartdrift_offline_nativeapp_RaceActivity_nativeFrame(JNIEnv* env,jclass){
    auto now=std::chrono::steady_clock::now();float dt=std::chrono::duration<float>(now-previous).count();previous=now;
    game->tick(dt,controls);sound.update(*game);auto frame=drift::makeFrame(*game,float(width)/height);
    glClear(GL_COLOR_BUFFER_BIT|GL_DEPTH_BUFFER_BIT);glUseProgram(program);glBindVertexArray(vao);glBindBuffer(GL_ARRAY_BUFFER,vbo);
    glBufferData(GL_ARRAY_BUFFER,frame.vertices.size()*sizeof(drift::Vertex),frame.vertices.data(),GL_STREAM_DRAW);
    glUniformMatrix4fv(matrix,1,GL_FALSE,frame.viewProjection.m);glDrawArrays(GL_TRIANGLES,0,frame.vertices.size());
    std::string hud=game->hud();if(game->autopilot)hud+=" · 自动驾驶测试";
    return env->NewStringUTF(hud.c_str());
}
extern "C" JNIEXPORT void JNICALL Java_org_kartdrift_offline_nativeapp_RaceActivity_nativeAction(JNIEnv*,jclass,jint action,jboolean down){
    if(!game)return;
    if(action==7)controls.steer=down?-1:0;if(action==8)controls.steer=down?1:0;
    if(action==9)controls.drift=down;if(action==10)controls.use=down;if(action==11)controls.brake=down?1:0;
    if(down){if(action<3){game->start(static_cast<drift::Mode>(action));controls={};}
        if(action==3){game->start(game->mode);controls={};}if(action==4)game->rescue(0);
        if(action==5)game->paused=!game->paused;if(action==6)game->autopilot=!game->autopilot;
        if(action==12){game->paused=true;controls={};}}
}
extern "C" JNIEXPORT jfloat JNICALL Java_org_kartdrift_offline_nativeapp_RaceActivity_nativeFinishTime(JNIEnv*,jclass){return game&&game->karts[0].finished?game->karts[0].finishTime:0;}
