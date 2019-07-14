#include "cuda_utils.h"
#include "macros.hpp"
#include <ATen/ExpandUtils.h>
#include <ATen/cuda/CUDAContext.h>
#include <ATen/cuda/CUDAUtils.h>
#include <c10/core/ScalarType.h>
#include <stdio.h>
#include <torch/extension.h>

/*
 return the indice of current point in the idxList
 -1 outside
 >= 0 inside
 */
template <typename indice_t>
__device__ void is_inside(const int topK, const indice_t *__restrict__ idxList,
                          const indice_t curr_Idx, int *curK) {
  for (size_t i = 0; i < topK; i++) {
    // a pixel is inside the splat if idxList contains point index
    if (idxList[i] == curr_Idx) {
      *curK = i;
      return;
    }
    // a pixel definitely isn't inside a splat if it's not occupied by any point
    if (idxList[i] == -1) {
      *curK = -1;
      return;
    }
  }
  *curK = -1;
  return;
}

/* compute pixel color after removing a point from a merged pixel */
// TODO curPointList probably no necessary, since rhoList and WsList will be
// zero at curPointList[k] == -1
template <typename scalar_t, typename indice_t>
__device__ void after_removal(const int numColors, const int topK,
                              const int curK, const scalar_t depthThres,
                              const scalar_t *depthList,
                              const indice_t *curPointList, // topK
                              const uint8_t *curIsBehind,   // topK
                              const scalar_t *wsList,       // topKx3
                              const scalar_t *rhoList,      // topKx1
                              const scalar_t *curPixel,     // numColors
                              scalar_t *newColors,          // numColors
                              scalar_t *newDepth) {
  // initialize color with 0.0
  for (int c = 0; c < numColors; c++) 
    newColors[c] = 0.0;
  
  // initialize depth with the farthest so far
  *newDepth = depthList[topK - 1];

  scalar_t sumRho = 0.0;
  int numVisible = 0;
  for (int k = 0; k < topK; k++) {
    if (curIsBehind[k] == 0)
      ++numVisible;
  }
  // if it's the only visible point, then removing it will reveal the
  // color below
  assert(numVisible >= 0);
  if (numVisible == 1) 
  {
    sumRho = 0.0;
    // CHECK: should be the second?
    const scalar_t curDepth = depthList[1];
    
    for(int k = curK + 1; k < topK; k++) 
    {
      // as soon as idxList is -1 or depth > currentDepth+threshold
      // stop accumulating colors
      if (curPointList[k] == -1) 
        break;

      if ((depthList[k] - curDepth) > depthThres) 
        break;
        
      for (int c = 0; c < numColors; c++) 
        newColors[c] += wsList[k * numColors + c] * rhoList[k];
      
      sumRho += rhoList[k];

      if (depthList[k] < *newDepth) 
        *newDepth = depthList[k];
    }

    for (int c = 0; c < numColors; c++) 
      newColors[c] /= (sumRho + 1e-8);

    return;
  }

  // not the only point visible:
  // removing current point involves reweighting rhos
  for (size_t k = 0; k < numVisible; k++) 
  {
    if (k == curK) 
      continue;
      
    for (size_t c = 0; c < numColors; c++) 
      newColors[c] += wsList[k * numColors + c] * rhoList[k];
      
    sumRho += rhoList[k];

    if (depthList[k] < *newDepth) 
      *newDepth = depthList[k];
  }

  for (size_t c = 0; c < numColors; c++) 
    newColors[c] /= (sumRho + 1e-8);
    
  assert(sumRho > 0);
  return;
}

/* compute pixel color after moving a point to a merged pixel */
template <typename scalar_t>
__device__ void
after_addition(const int numColors, const int topK, const scalar_t rho,
               const scalar_t *ws, const scalar_t pointDepth,
               const scalar_t depthThres, const scalar_t *depthList,
               const uint8_t *curIsBehind, // topK
               const scalar_t *wsList,     // topKx3
               const scalar_t *rhoList,    // topKx1
               const scalar_t *curPixel,   // numColors
               scalar_t *newColors,        // numColors
               scalar_t *newDepth) {
  scalar_t sumRho = rho;
  for (size_t k = 0; k < topK; k++) {
    if (curIsBehind[k] > 0 ||
        (depthList[k] - depthThres) > pointDepth) { // || (depthList[k] - depthThres) > pointDepth
      break;
    }
    sumRho += rhoList[k];
  }

  if (sumRho == 0) {
    sumRho += 1e-5;
  }

  for (size_t c = 0; c < numColors; c++) 
    newColors[c] = rho / sumRho * ws[c];

  for (size_t k = 0; k < topK; k++) {
    for (size_t c = 0; c < numColors; c++) {
      if (curIsBehind[k] > 0 ||
          (depthList[k] - depthThres) >
              pointDepth) { // || (depthList[k] - depthThres) > pointDepth
        break;
      }
      newColors[c] += rhoList[k] / sumRho * wsList[k * numColors + c];
    }
  }
  *newDepth = min(depthList[0], pointDepth);
}

/*
  compute pixel color after moving a point closer to the screen
 */
template <typename scalar_t>
__device__ void after_drawing_closer(const int numColors, const int topK,
                                     const int curK,
                                     const scalar_t *wsList,    // topKx3
                                     const scalar_t *rhoList,   // topKx1
                                     const scalar_t *depthList, // topK
                                     const uint8_t *isBehind,   // topK
                                     scalar_t *newColors, scalar_t *newDepth) {
  scalar_t curRho = rhoList[curK];
  const scalar_t *curW = wsList + curK * numColors;
  scalar_t pointDepth = depthList[curK];
  scalar_t sumRho = curRho;
  for (size_t k = 0; k < topK; k++) {
    if (isBehind[k] > 0) {
      break;
    }
    sumRho += rhoList[k];
  }
  // should at least have curRho
  assert(sumRho > 0);
  for (size_t c = 0; c < numColors; c++) {
    newColors[c] = curRho / sumRho * curW[c];
  }

  for (size_t k = 0; k < topK; k++) {
    for (size_t c = 0; c < numColors; c++) {
      if (isBehind[k] > 0) {
        break;
      }
      newColors[c] += rhoList[k] / sumRho * wsList[k * numColors + c];
    }
  }
  *newDepth = min(depthList[0], pointDepth);
}

template <typename scalar_t> __device__ scalar_t eps_guard(scalar_t v) {
  const scalar_t eps = 0.01;
  if (v < 0) {
    return v - eps;
  }
  if (v >= 0) {
    return v + eps;
  }
  // return v;
}
/*
  a point is not "bad", i.e. don't need to be moved, when it's colorGrads is
  zero within its effective extent (pointIdxMap include pointID && rhoMap > 0)
 */
template <typename scalar_t, typename indice_t>
__global__ void whitelist_points(
    const int imgHeight, const int imgWidth, const int topK, const int PN,
    const int batchSize, const int WDim,
    const scalar_t *__restrict__ colorGrads,    // BxHxWx3 gradient from output
    const indice_t *__restrict__ pointIdxMap,   // BxHxWxtopK
    const uint8_t *__restrict__ isBehind,       // BxHxWxtopK
    const indice_t *__restrict__ boundingBoxes, // BxNx4 xmin ymin xmax ymax
    uint8_t *whitelist_mask                     // BxNx1
) {
  const int numPixels = imgHeight * imgWidth;
  const scalar_t eps = 1e-9;
  // loop all points
  for (int b = blockIdx.x; b < batchSize; b += gridDim.x) {
    for (indice_t p = threadIdx.x + blockDim.x * blockIdx.y; p < PN;
         p += blockDim.x * gridDim.y) {
      const size_t curPointIdx = b * PN + p;
      const indice_t *curBB = boundingBoxes + curPointIdx * 4;
      const indice_t xmin = curBB[0];
      const indice_t ymin = curBB[1];
      const indice_t xmax = curBB[2];
      const indice_t ymax = curBB[3];
      // search within the bounding box
      bool isGood = true;
      bool inExtent = false;
      for (size_t h = ymin; h < ymax; h++) {
        for (size_t w = xmin; w < xmax; w++) {
          const indice_t curPixelIdx = b * numPixels + h * imgWidth + w;
          scalar_t colorGrad = 0.0;
          for (size_t c = 0; c < WDim; c++) {
            colorGrad += abs(colorGrads[curPixelIdx * WDim + c]);
          }
          // temporary flag for current pixel
          bool _isGood = true;
          bool _inExtent = false;
          for (size_t k = 0; k < topK; k++) {
            // inside the extent and is shown
            if (pointIdxMap[curPixelIdx * topK + k] == p) {
              _inExtent = true;
              // is bad if some pixel inside the splat radius is not shown
              // (isBehind) or colorGrad > threshold
              _isGood =
                  !(isBehind[curPixelIdx * topK + k] > 0 || (colorGrad) > eps);
            }
          }
          // there is one pixel in extent
          inExtent = inExtent | _inExtent;
          // as long as one pixel is not good, this point is not good
          isGood = _isGood & isGood;
        }
      }
      // if all pixels are not in extent, then this point is bad
      whitelist_mask[curPointIdx] = inExtent & isGood;
    }
  }
}
/*  */
template <typename scalar_t, typename indice_t>
__global__ void visibility_backward_kernel(
    const int batchSize, const int imgHeight, const int imgWidth,
    const int localHeight, const int localWidth, const int topK, const int PN,
    const int projDim, const int WDim, const scalar_t focalL,
    const scalar_t mergeT, const bool considerZ,
    const scalar_t *__restrict__ colorGrads,    // BxHxWxC gradient from output
    const indice_t *__restrict__ pointIdxMap,   // BxHxWxtopK
    const scalar_t *__restrict__ rhoMap,        // BxHxWxtopK
    const scalar_t *__restrict__ wsMap,         // BxHxWxtopKxC
    const scalar_t *__restrict__ depthMap,      // BxHxWxtopK
    const uint8_t *__restrict__ isBehind,       // BxHxWxtopK
    const scalar_t *__restrict__ pixelValues,   // BxHxWxC
    const indice_t *__restrict__ boundingBoxes, // BxNx4 xmin ymin xmax ymax
    const scalar_t *__restrict__ projPoints,    // BxNx[2or3], xy1
    const scalar_t *__restrict__ pointColors,   // BxNxC
    const scalar_t *__restrict__ depthValues,   // BxNx1
    const scalar_t *__restrict__ rhoValues,     // BxNx1
    scalar_t *__restrict__ dIdp, // BxNx2 gradients for screenX and screenY
    scalar_t *__restrict__ dIdz) // BxNx1 gradients for z
{
  // const scalar_t mergeT = scalar_t(mergeThres);
  // const scalar_t focalL = scalar_t(focalLength);
  const int numPixels = imgHeight * imgWidth;
  // loop all points
  for (int b = blockIdx.x; b < batchSize; b += gridDim.x) {
    for (indice_t p = threadIdx.x + blockDim.x * blockIdx.y; p < PN;
         p += blockDim.x * gridDim.y) {
      const indice_t curPointIdx = b * PN + p;
      // skip point (gradient=0) if mask == 1 (i.e. point is good)
      scalar_t xmin = scalar_t(boundingBoxes[curPointIdx * 4]);
      scalar_t ymin = scalar_t(boundingBoxes[curPointIdx * 4 + 1]);
      // scalar_t xmax = scalar_t(boundingBoxes[curPointIdx * 4 + 2]);
      // scalar_t ymax = scalar_t(boundingBoxes[curPointIdx * 4 + 3]);
      const scalar_t *curPointColor = pointColors + curPointIdx * WDim;
      const scalar_t *curProjValues = projPoints + curPointIdx * projDim;
      scalar_t *dIdx = dIdp + curPointIdx * projDim;
      scalar_t *dIdy = dIdp + curPointIdx * projDim + 1;
      scalar_t *curdIdz = dIdz + curPointIdx;
      const scalar_t rhov = rhoValues[curPointIdx];
      const int bH =
          min(max(0, int(curProjValues[1] - localHeight / 2)), imgHeight);
      const int eH =
          max(min(imgHeight, int(curProjValues[1] + localHeight / 2 + 1)), 0);
      const int bW =
          min(max(0, int(curProjValues[0] - localWidth / 2)), imgWidth);
      const int eW =
          max(min(imgWidth, int(curProjValues[0] + localWidth / 2 + 1)), 0);
      // loop all pixels
      for (size_t i = bH; i < eH; i++) {
        for (size_t j = bW; j < eW; j++) {
          const indice_t curPixelIdx = (b * numPixels + i * imgWidth + j);
          const scalar_t *curColorGrad = colorGrads + curPixelIdx * WDim;
          const scalar_t *curWs = wsMap + curPixelIdx * topK * WDim;
          const scalar_t *curRhos = rhoMap + curPixelIdx * topK;
          // const indice_t curClosest = pointIdxMap[curPixelIdx * topK];
          // const indice_t curClosestIdx = b * PN + curClosest;
          const indice_t *curIdxList = pointIdxMap + curPixelIdx * topK;
          const scalar_t *curPixelValues = pixelValues + curPixelIdx * WDim;
          const scalar_t *curDepthList = depthMap + curPixelIdx * topK;
          // const scalar_t curClosestDepth = depthMap[curPixelIdx * topK];
          const uint8_t *curIsBehind = isBehind + curPixelIdx * topK;
          const scalar_t curPointDepth = depthValues[curPointIdx];
          // is this pixel inside the splat?
          int curK;
          is_inside(topK, curIdxList, curPointIdx, &curK);
          scalar_t didxv = 0.0;
          scalar_t didyv = 0.0;
          scalar_t didzv = 0.0;
          scalar_t dldI = 0.0;
          scalar_t newColors[10];
          scalar_t newDepth;

          // outside
          if (curK < 0) 
          {
            after_addition(WDim, topK, rhov, curPointColor, curPointDepth,
                           mergeT, curDepthList, curIsBehind, curWs, curRhos,
                           curPixelValues, newColors, &newDepth);

            for (size_t c = 0; c < WDim; c++) 
              dldI += (newColors[c] - curPixelValues[c]) * curColorGrad[c];
              
            if (dldI < 0.0) 
            {
              // another point at pixel i,j is in front of the current point by
              // a threshold, need to change z, otherwise moving to that
              // direction won't change the color value
              if (curPointDepth - newDepth > mergeT) 
              {
                if (!considerZ) 
                  continue;
                  
                scalar_t dx = (scalar_t(j) - curProjValues[0]);
                scalar_t dy = (scalar_t(i) - curProjValues[1]);
                scalar_t dx_3d = (scalar_t(j) - curProjValues[0]) / focalL /
                                 imgWidth * 2 * curPointDepth;
                scalar_t dy_3d = (scalar_t(i) - curProjValues[1]) / focalL /
                                 imgHeight * 2 * curPointDepth;
                assert(newDepth < curPointDepth);
                scalar_t dz_3d = newDepth - curPointDepth;
                scalar_t distance2_3d =
                    eps_guard(dx_3d * dx_3d + dy_3d * dy_3d + dz_3d * dz_3d);
                scalar_t distance2 = eps_guard(dx * dx + dy * dy);
                didzv = dldI / distance2_3d * dz_3d;
                // should rescale to screen space
                didxv = dldI / distance2 * dx;
                didyv = dldI / distance2 * dy;
                assert(!isnan(didxv));
                assert(!isnan(didyv));
              } 
              else // don't need to change z
              {
                scalar_t dx = (scalar_t(j) - curProjValues[0]);
                scalar_t dy = (scalar_t(i) - curProjValues[1]);
                scalar_t distance2 = eps_guard(dx * dx + dy * dy);
                // dIdx
                didxv = dldI / distance2 * dx;
                // dIdy
                didyv = dldI / distance2 * dy;
                assert(!isnan(didxv));
                assert(!isnan(didyv));
              }
            }
          }
          // pixel inside splat
          else // i.e. curK >= 0
          {
            // is the current point shown?
            if (curIsBehind[curK] < 1) // yes
            {
              // dIdx dIdy and dIdz-
              after_removal(WDim, topK, curK, mergeT, curDepthList, curIdxList,
                            curIsBehind, curWs, curRhos, curPixelValues,
                            newColors, &newDepth);

              for (size_t c = 0; c < WDim; c++) 
                dldI += (newColors[c] - curPixelValues[c]) * curColorGrad[c];

              if (dldI < 0.0) 
              {
                // dIdp = (dIdp+) + (dIdp-)
                scalar_t dx = (scalar_t(j) - curProjValues[0]);
                scalar_t dy = (scalar_t(i) - curProjValues[1]);
                scalar_t distance = sqrt(eps_guard(dx * dx + dy * dy));
                scalar_t rx = curProjValues[0] - xmin;
                scalar_t ry = curProjValues[1] - ymin;
                assert(rx > 0);
                assert(ry > 0);
                scalar_t r = max(rx, ry);
                didxv = dldI * dx / eps_guard((r + distance) * distance) +
                        dldI * dx / eps_guard((distance - r) * distance);
                didyv = dldI * dy / eps_guard((r + distance) * distance) +
                        dldI * dy / eps_guard((distance - r) * distance);
                assert(!isnan(didxv));
                assert(!isnan(didyv));
              }
            } // endif (curRhos[curK] > 0)
            // point is not visible:
            else // i.e. curIsBehind[curK] >= 1
            {
              if (!considerZ)
                continue;
              // this point is occluded by other points, moving closer will
              // change the color
              after_drawing_closer(WDim, topK, curK, curWs, curRhos,
                                   curDepthList, curIsBehind, newColors,
                                   &newDepth);
              for (size_t c = 0; c < WDim; c++) {
                dldI += (newColors[c] - curPixelValues[c]) * curColorGrad[c];
              }
              if (dldI < 0.0) {
                didzv = dldI / eps_guard(newDepth - curPointDepth);
              }
            } // endif on top
          }   // endif inside

          (*curdIdz) += didzv;
          (*dIdx) += didxv;
          (*dIdy) += didyv;
        } // imWidth
      }   // imHeight
    }     // point
  }       // batch
}

// dIdp BxNx2 dx dy, dIdz BxNx1
std::vector<at::Tensor>
visibility_backward_cuda(const double focalLength, const double mergeThres,
                         const bool considerZ, const int localHeight,
                         const int localWidth,
                         const at::Tensor &colorGrads,    // BxHxWxWDim
                         const at::Tensor &pointIdxMap,   // BxHxWxtopK
                         const at::Tensor &rhoMap,        // BxHxWxtopK
                         const at::Tensor &wsMap,         // BxHxWxtopKxWDim
                         const at::Tensor &depthMap,      // BxHxWxtopK
                         const at::Tensor &isBehind,      // BxHxWxtopK
                         const at::Tensor &pixelValues,   // BxHxWxWDim
                         const at::Tensor &boundingBoxes, // BxNx4
                         const at::Tensor &projPoints,    // BxNx[2or3]
                         const at::Tensor &pointColors,   // BxNxWDim
                         const at::Tensor &depthValues,   // BxNx1
                         const at::Tensor &rhoValues,     // BxNx1
                         at::Tensor &dIdp, at::Tensor &dIdz) {
  const int batchSize = pointIdxMap.size(0);
  const int imgHeight = pointIdxMap.size(1);
  const int imgWidth = pointIdxMap.size(2);
  const int topK = pointIdxMap.size(3);
  const int PN = projPoints.size(1);
  const int WDim = pointColors.size(2);
  CHECK(projPoints.size(2) == 2 || projPoints.size(2) == 3);
  const int projDim = projPoints.size(2);
  CHECK_EQ(pointColors.size(1), PN);
  CHECK(colorGrads.size(-1) == wsMap.size(-1) &&
        wsMap.size(-1) == pixelValues.size(-1) &&
        pixelValues.size(-1) == pointColors.size(-1));
  std::vector<at::Tensor> outputs;
  unsigned int n_threads, n_blocks;
  n_threads = opt_n_threads(PN);
  n_blocks = min(32, (PN * batchSize + n_threads - 1) / n_threads);
  // initialize with zeros
  dIdp.zero_();
  dIdz.zero_();
  cudaStream_t stream = at::cuda::getCurrentCUDAStream();

  std::vector<at::Tensor> output;

  AT_DISPATCH_FLOATING_TYPES_AND_HALF(
      colorGrads.type(), "visibility_backward_kernel", ([&] {
        visibility_backward_kernel<scalar_t, int64_t>
            <<<dim3(batchSize, n_blocks, 1), n_threads, 0, stream>>>(
                batchSize, imgHeight, imgWidth, localHeight, localWidth, topK,
                PN, projDim, WDim, focalLength, mergeThres, considerZ,
                colorGrads.data<scalar_t>(),  // BxHxWx3
                pointIdxMap.data<int64_t>(),  // BxHxWxtopK
                rhoMap.data<scalar_t>(),      // BxHxWxtopK
                wsMap.data<scalar_t>(),       // BxHxWxtopKx3
                depthMap.data<scalar_t>(),    // BxHxWxtopK
                isBehind.data<uint8_t>(),     // BxHxWxtopK
                pixelValues.data<scalar_t>(), // BxHxWx3
                boundingBoxes.toType(pointIdxMap.scalar_type())
                    .data<int64_t>(),         // BxNx4 xmin ymin xmax ymax
                projPoints.data<scalar_t>(),  // BxNx[2or3], xy1
                pointColors.data<scalar_t>(), // BxNx3
                depthValues.data<scalar_t>(), // BxNx1
                rhoValues.data<scalar_t>(),   // BxNx1
                dIdp.data<scalar_t>(),        // BxNx2 gradients for projX,Y
                dIdz.data<scalar_t>()         // BxNx1
            );                                // BxHxWx8
      }));
  output.push_back(dIdp);
  output.push_back(dIdz);

  cudaError_t err = cudaDeviceSynchronize();
  if (err != cudaSuccess) {
    printf("compute_visiblity_maps_cuda kernel failed: %s\n",
           cudaGetErrorString(err));
    exit(-1);
  }
  return output;
}