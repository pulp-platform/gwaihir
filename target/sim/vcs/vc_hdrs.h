#ifndef _VC_HDRS_H
#define _VC_HDRS_H

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <stdio.h>
#include <dlfcn.h>
#include "svdpi.h"

#ifdef __cplusplus
extern "C" {
#endif

#ifndef _VC_TYPES_
#define _VC_TYPES_
/* common definitions shared with DirectC.h */

typedef unsigned int U;
typedef unsigned char UB;
typedef unsigned char scalar;
typedef struct { U c; U d;} vec32;

#define scalar_0 0
#define scalar_1 1
#define scalar_z 2
#define scalar_x 3

extern long long int ConvUP2LLI(U* a);
extern void ConvLLI2UP(long long int a1, U* a2);
extern long long int GetLLIresult();
extern void StoreLLIresult(const unsigned int* data);
typedef struct VeriC_Descriptor *vc_handle;

#ifndef SV_3_COMPATIBILITY
#define SV_STRING const char*
#else
#define SV_STRING char*
#endif

#endif /* _VC_TYPES_ */


 extern char read_elf(/* INPUT */const char* filename);

 extern char get_entry(/* OUTPUT */long long *entry);

 extern char get_section(/* OUTPUT */long long *address, /* OUTPUT */long long *len);

 extern char read_section(/* INPUT */long long address, const /* INOUT */svOpenArrayHandle buffer, /* INPUT */long long len);

 extern void* svapfGetAttempt(/* INPUT */unsigned int assertHandle);

 extern void svapfReportResult(/* INPUT */unsigned int assertHandle, /* INPUT */void* ptrAttempt, /* INPUT */int result);

 extern int svapfGetAssertEnabled(/* INPUT */unsigned int assertHandle);

 extern char read_elf(/* INPUT */const char* filename);

 extern char get_entry(/* OUTPUT */long long *entry);

 extern char get_section(/* OUTPUT */long long *address, /* OUTPUT */long long *len);

 extern char read_section(/* INPUT */long long address, const /* INOUT */svOpenArrayHandle buffer, /* INPUT */long long len);
void SdisableFork();

#ifdef __cplusplus
}
#endif


#endif //#ifndef _VC_HDRS_H

