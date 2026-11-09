// Observe-only: timestamps input reports of 045E:02E0 (GDHub pad) and 045E:028E (Apple GC synthetic) for N seconds.
#include <IOKit/hid/IOHIDManager.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static mach_timebase_info_data_t tb;
static double now_ms(void){ return (double)mach_absolute_time()*tb.numer/tb.denom/1e6; }
typedef struct { int pid; uint8_t buf[64]; } ctx_t;
static FILE *out;
static void cb(void *c, IOReturn r, void *sender, IOHIDReportType t, uint32_t id, uint8_t *rep, CFIndex len){
  ctx_t *x=(ctx_t*)c; fprintf(out,"%.3f %04x %ld", now_ms(), x->pid, (long)len);
  for(int i=0;i<len && i<16;i++) fprintf(out," %02x",rep[i]); fprintf(out,"\n");
}
static void added(void *c, IOReturn r, void *s, IOHIDDeviceRef d){
  CFNumberRef p=IOHIDDeviceGetProperty(d,CFSTR(kIOHIDProductIDKey)); int pid=0; CFNumberGetValue(p,kCFNumberIntType,&pid);
  CFStringRef cls=IOHIDDeviceGetProperty(d,CFSTR("IOClass"));
  fprintf(stderr,"added pid %04x\n",pid);
  ctx_t *x=calloc(1,sizeof *x); x->pid=pid;
  IOHIDDeviceRegisterInputReportCallback(d,x->buf,sizeof x->buf,cb,x);
}
static CFDictionaryRef match(int vid,int pid){
  CFMutableDictionaryRef m=CFDictionaryCreateMutable(NULL,0,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
  CFNumberRef v=CFNumberCreate(NULL,kCFNumberIntType,&vid), p=CFNumberCreate(NULL,kCFNumberIntType,&pid);
  CFDictionarySetValue(m,CFSTR(kIOHIDVendorIDKey),v); CFDictionarySetValue(m,CFSTR(kIOHIDProductIDKey),p); return m;
}
int main(int argc,char**argv){
  mach_timebase_info(&tb); double secs=argc>1?atof(argv[1]):10; out=stdout;
  IOHIDManagerRef m=IOHIDManagerCreate(NULL,kIOHIDOptionsTypeNone);
  CFDictionaryRef a[2]={match(0x045e,0x02e0),match(0x045e,0x028e)};
  CFArrayRef arr=CFArrayCreate(NULL,(const void**)a,2,&kCFTypeArrayCallBacks);
  IOHIDManagerSetDeviceMatchingMultiple(m,arr);
  IOHIDManagerRegisterDeviceMatchingCallback(m,added,NULL);
  IOHIDManagerScheduleWithRunLoop(m,CFRunLoopGetCurrent(),kCFRunLoopDefaultMode);
  IOReturn r=IOHIDManagerOpen(m,kIOHIDOptionsTypeNone); fprintf(stderr,"open=0x%x\n",r);
  CFRunLoopRunInMode(kCFRunLoopDefaultMode,secs,false);
  fflush(out); return 0;
}
