#include <stdio.h>
#include <string.h>
#include <time.h>
#include <gbm.h>
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>
int main(int argc,char**argv){
  int W=atoi(argv[1]),H=atoi(argv[2]);
  int fd=open("/dev/dri/renderD128",O_RDWR);
  struct gbm_device*gd=gbm_create_device(fd);
  struct gbm_surface*gs=gbm_surface_create(gd,W,H,GBM_FORMAT_XRGB8888,GBM_BO_USE_RENDERING|GBM_BO_USE_LINEAR);
  EGLDisplay d=eglGetDisplay(gd);eglInitialize(d,0,0);
  eglBindAPI(EGL_OPENGL_ES_API);
  EGLint ca[]={EGL_SURFACE_TYPE,EGL_WINDOW_BIT,EGL_RENDERABLE_TYPE,EGL_OPENGL_ES2_BIT,EGL_RED_SIZE,8,EGL_GREEN_SIZE,8,EGL_BLUE_SIZE,8,EGL_NONE};
  EGLConfig cfg;EGLint n;eglChooseConfig(d,ca,&cfg,1,&n);
  EGLint cx[]={EGL_CONTEXT_CLIENT_VERSION,2,EGL_NONE};
  EGLContext ctx=eglCreateContext(d,cfg,EGL_NO_CONTEXT,cx);
  EGLSurface s=eglCreateWindowSurface(d,cfg,gs,NULL);
  eglMakeCurrent(d,s,s,ctx);
  printf("GL_RENDERER=%s\nGL_VENDOR=%s\nGL_VERSION=%s\n",glGetString(GL_RENDERER),glGetString(GL_VENDOR),glGetString(GL_VERSION));
  int nf=0;struct timespec t0,t1;clock_gettime(CLOCK_MONOTONIC,&t0);
  for(;;){
    eglMakeCurrent(d,s,s,ctx);
    glClearColor(0.1f,0.2f,0.3f,1);glClear(GL_COLOR_BUFFER_BIT);
    for(int i=0;i<40;i++){glViewport(0,0,W,H);glClearColor(i/40.f,0.5f,0.9f,1);glScissor((i*97)%W,(i*211)%H,120,120);glEnable(GL_SCISSOR_TEST);glClear(GL_COLOR_BUFFER_BIT);glDisable(GL_SCISSOR_TEST);}
    glFinish();
    eglSwapBuffers(d,s);
    nf++;
    clock_gettime(CLOCK_MONOTONIC,&t1);
    double el=(t1.tv_sec-t0.tv_sec)+(t1.tv_nsec-t0.tv_nsec)/1e9;
    if(el>3.0){printf("fps=%.1f frames=%d\n",nf/el,nf);break;}
  }
  return 0;
}
