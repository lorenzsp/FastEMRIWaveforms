#ifndef hZ_10mkP8_5PNe10_H_ 
#define hZ_10mkP8_5PNe10_H_ 

/*
  Header of the PN Teukolsky amplitude Zlmkn8 (ell = 10, n = 8)

  25th May 2020; RF
  20th June. 2020; Sis

*/

//! \file hZ_10mkP8_5PNe10.h

#include "global.h"

// BHPC headers
#include "Zlmkn8_5PNe10.h"


// Define type


// Declare prototype 
CUDA_CALLABLE_MEMBER
cmplx hZ_10mkP8(const int m, const int k, inspiral_orb_PNvar* PN_orb);

#endif // hZ_10mkP8_5PNe10_H_ 