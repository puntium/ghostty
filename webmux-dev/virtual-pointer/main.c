// Persistent virtual pointer: reads commands on stdin.
// abs X Y | down [btn] | up [btn] | scroll DX DY (wheel, discrete) | hscroll DX (finger, continuous) | sleep MS
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <wayland-client.h>
#include "vp.h"
static struct zwlr_virtual_pointer_manager_v1 *mgr; static struct wl_seat *seat;
static void reg(void *d, struct wl_registry *r, uint32_t name, const char *iface, uint32_t v){
  if(!strcmp(iface, zwlr_virtual_pointer_manager_v1_interface.name)) mgr=wl_registry_bind(r,name,&zwlr_virtual_pointer_manager_v1_interface,1);
  else if(!strcmp(iface, wl_seat_interface.name)) seat=wl_registry_bind(r,name,&wl_seat_interface,1);
}
static void rem(void*d, struct wl_registry*r, uint32_t n){}
static const struct wl_registry_listener rl={reg,rem};
static uint32_t now(){struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return t.tv_sec*1000+t.tv_nsec/1000000;}
int main(int argc,char**argv){
  int W=atoi(argv[1]),H=atoi(argv[2]);
  struct wl_display*dpy=wl_display_connect(NULL); if(!dpy){fprintf(stderr,"no display\n");return 1;}
  struct wl_registry*r=wl_display_get_registry(dpy); wl_registry_add_listener(r,&rl,NULL); wl_display_roundtrip(dpy);
  if(!mgr){fprintf(stderr,"no vp manager\n");return 1;}
  struct zwlr_virtual_pointer_v1*p=zwlr_virtual_pointer_manager_v1_create_virtual_pointer(mgr,seat);
  wl_display_roundtrip(dpy);
  char line[256];
  while(fgets(line,sizeof line,stdin)){
    char c[32]; double a=0,b=0; int n=sscanf(line,"%31s %lf %lf",c,&a,&b); if(n<1) continue;
    if(!strcmp(c,"abs")) { zwlr_virtual_pointer_v1_motion_absolute(p,now(),(uint32_t)a,(uint32_t)b,W,H); zwlr_virtual_pointer_v1_frame(p);}
    else if(!strcmp(c,"down")) { zwlr_virtual_pointer_v1_button(p,now(),n>1?(uint32_t)a:0x110,1); zwlr_virtual_pointer_v1_frame(p);}
    else if(!strcmp(c,"up")) { zwlr_virtual_pointer_v1_button(p,now(),n>1?(uint32_t)a:0x110,0); zwlr_virtual_pointer_v1_frame(p);}
    else if(!strcmp(c,"scroll")) { zwlr_virtual_pointer_v1_axis_source(p,0);
      if(a) zwlr_virtual_pointer_v1_axis_discrete(p,now(),1,wl_fixed_from_double(a*15),(int)a);
      if(b) zwlr_virtual_pointer_v1_axis_discrete(p,now(),0,wl_fixed_from_double(b*15),(int)b);
      zwlr_virtual_pointer_v1_frame(p);}
    else if(!strcmp(c,"fscroll")) { zwlr_virtual_pointer_v1_axis_source(p,1);
      if(a) zwlr_virtual_pointer_v1_axis(p,now(),1,wl_fixed_from_double(a));
      if(b) zwlr_virtual_pointer_v1_axis(p,now(),0,wl_fixed_from_double(b));
      zwlr_virtual_pointer_v1_frame(p);}
    else if(!strcmp(c,"wscroll")) { zwlr_virtual_pointer_v1_axis_source(p,0);
      if(a) zwlr_virtual_pointer_v1_axis(p,now(),1,wl_fixed_from_double(a));
      if(b) zwlr_virtual_pointer_v1_axis(p,now(),0,wl_fixed_from_double(b));
      zwlr_virtual_pointer_v1_frame(p);}
    else if(!strcmp(c,"fstop")) { zwlr_virtual_pointer_v1_axis_source(p,1); zwlr_virtual_pointer_v1_axis_stop(p,now(),1); zwlr_virtual_pointer_v1_axis_stop(p,now(),0); zwlr_virtual_pointer_v1_frame(p);}
    else if(!strcmp(c,"sleep")) { wl_display_flush(dpy); usleep((useconds_t)(a*1000)); }
    // Let the compositor and the client see each step before the next:
    // a press sent in the same burst as the motion that precedes it can
    // land before the surface has the pointer.
    wl_display_roundtrip(dpy); usleep(20000);
  }
  wl_display_roundtrip(dpy); usleep(200000);
  zwlr_virtual_pointer_v1_destroy(p); wl_display_roundtrip(dpy); return 0;
}
