#include <cooperative_groups.h>
#include <curand_kernel.h>

#include "utils.h.cu"
#include "builtin_types.h"
#include "helper_math.h"
#include "HostDeviceInterface.h"

namespace cg = cooperative_groups;

Uniforms uniforms;
Allocator* allocator;
uint64_t nanotime_start;

constexpr float PI = 3.1415;

float4 operator*(const mat4& a, const float4& b){
	return make_float4(
		dot(a.rows[0], b),
		dot(a.rows[1], b),
		dot(a.rows[2], b),
		dot(a.rows[3], b)
	);
}

struct Triangles{
	int numTriangles;
	float3* positions;
	float2* uvs;
	uint32_t* colors;
};

struct Texture{
	int width;
	int height;
	uint32_t* data;
};

struct RasterizationSettings{
	Texture* texture = nullptr;
	int colorMode = COLORMODE_TRIANGLE_ID;
};

uint32_t sample_nearest(float2 uv, Texture* texture){
	int tx = int(uv.x * texture->width) % texture->width;
	int ty = int(uv.y * texture->height) % texture->height;
	ty = texture->height - ty;

	int texelIndex = tx + texture->width * ty;
	uint32_t texel = texture->data[texelIndex];

	return texel;
}

uint32_t sample_linear(float2 uv, Texture* texture){
	float width = texture->width;
	float height = texture->height;

	float tx = uv.x * width;
	float ty = height - uv.y * height;

	int x0 = clamp(floor(tx), 0.0f, width - 1.0f);
	int x1 = clamp(ceil(tx) , 0.0f, width - 1.0f);
	int y0 = clamp(floor(ty), 0.0f, height - 1.0f);
	int y1 = clamp(ceil(ty) , 0.0f, height - 1.0f);
	float wx = tx - floor(tx);
	float wy = ty - floor(ty);

	float w00 = (1.0 - wx) * (1.0 - wy);
	float w10 = wx * (1.0 - wy);
	float w01 = (1.0 - wx) * wy;
	float w11 = wx * wy;

	uint8_t* c00 = (uint8_t*)&texture->data[x0 + y0 * texture->width];
	uint8_t* c10 = (uint8_t*)&texture->data[x1 + y0 * texture->width];
	uint8_t* c01 = (uint8_t*)&texture->data[x0 + y1 * texture->width];
	uint8_t* c11 = (uint8_t*)&texture->data[x1 + y1 * texture->width];

	uint32_t color;
	uint8_t* rgb = (uint8_t*)&color;

	rgb[0] = c00[0] * w00 + c10[0] * w10 + c01[0] * w01 + c11[0] * w11;
	rgb[1] = c00[1] * w00 + c10[1] * w10 + c01[1] * w01 + c11[1] * w11;
	rgb[2] = c00[2] * w00 + c10[2] * w10 + c01[2] * w01 + c11[2] * w11;

	return color;
}

// rasterizes triangles in a block-wise fashion
// - each block grabs a triangle
// - all threads of that block process different fragments of the triangle
void rasterizeTriangles(Triangles* triangles, uint64_t* framebuffer, RasterizationSettings settings){

	auto grid = cg::this_grid();
	auto block = cg::this_thread_block();

	Texture* texture = settings.texture;
	int colorMode = settings.colorMode;

	uint32_t& processedTriangles = *allocator->alloc<uint32_t*>(4);
	if(grid.thread_rank() == 0){
		processedTriangles = 0;
	}
	grid.sync();

	{
		__shared__ int sh_triangleIndex;

		block.sync();

		// safety mechanism: each block draws at most <loop_max> triangles
		int loop_max = 10'000;
		for(int loop_i = 0; loop_i < loop_max; loop_i++){
			
			// grab the index of the next unprocessed triangle
			block.sync();
			if(block.thread_rank() == 0){
				sh_triangleIndex = atomicAdd(&processedTriangles, 1);
			}
			block.sync();

			if(sh_triangleIndex >= triangles->numTriangles) break;

			// project x/y to pixel coords
			// z: whatever 
			// w: linear depth
			auto toScreenCoord = [&](float3 p){
				float4 pos = uniforms.transform * float4{p.x, p.y, p.z, 1.0f};

				pos.x = pos.x / pos.w;
				pos.y = pos.y / pos.w;

				float4 imgPos = {
					(pos.x * 0.5f + 0.5f) * uniforms.width, 
					(pos.y * 0.5f + 0.5f) * uniforms.height,
					pos.z, 
					pos.w
				};

				return imgPos;
			};

			int i0 = 3 * sh_triangleIndex + 0;
			int i1 = 3 * sh_triangleIndex + 1;
			int i2 = 3 * sh_triangleIndex + 2;
			float3 v0 = triangles->positions[i0];
			float3 v1 = triangles->positions[i1];
			float3 v2 = triangles->positions[i2];

			float4 p0 = toScreenCoord(v0);
			float4 p1 = toScreenCoord(v1);
			float4 p2 = toScreenCoord(v2);

			// auto isInside = [&](float4 p){
			// 	if(p.x < 0 || p.x >= uniforms.width) return false;
			// 	if(p.y < 0 || p.y >= uniforms.height) return false;

			// 	return true;
			// };

			// if(!isInside(p0) || !isInside(p1) || !isInside(p2)) continue;

			// cull a triangle if one of its vertices is closer than depth 0
			if(p0.w < 0.0 || p1.w < 0.0 || p2.w < 0.0) continue;

			float2 v01 = float2{p1.x - p0.x, p1.y - p0.y};
			float2 v02 = float2{p2.x - p0.x, p2.y - p0.y};

			auto cross = [](float2 a, float2 b){ return a.x * b.y - a.y * b.x; };

			{// backface culling
				float w = cross(v01, v02);
				if(w < 0.0) continue;
			}

			// compute screen-space bounding rectangle
			float min_x = min(min(p0.x, p1.x), p2.x);
			float min_y = min(min(p0.y, p1.y), p2.y);
			float max_x = max(max(p0.x, p1.x), p2.x);
			float max_y = max(max(p0.y, p1.y), p2.y);

			// clamp to screen
			min_x = clamp(min_x, 0.0f, uniforms.width);
			min_y = clamp(min_y, 0.0f, uniforms.height);
			max_x = clamp(max_x, 0.0f, uniforms.width);
			max_y = clamp(max_y, 0.0f, uniforms.height);

			int size_x = ceil(max_x) - floor(min_x);
			int size_y = ceil(max_y) - floor(min_y);
			int numFragments = size_x * size_y;

			// iterate through fragments in bounding rectangle and draw if within triangle
			int numProcessedSamples = 0;
			for(int fragOffset = 0; fragOffset < numFragments; fragOffset += block.num_threads()){

				// safety mechanism: don't draw more than <x> pixels per thread
				if(numProcessedSamples > 5'000) break;

				int fragID = fragOffset + block.thread_rank();
				int fragX = fragID % size_x;
				int fragY = fragID / size_x;

				float2 pFrag = {
					floor(min_x) + float(fragX), 
					floor(min_y) + float(fragY)
				};
				float2 sample = {pFrag.x - p0.x, pFrag.y - p0.y};

				float s = cross(sample, v02) / cross(v01, v02);
				float t = cross(v01, sample) / cross(v01, v02);
				float v = 1.0 - (s + t);

				// v: vertex[0], s: vertex[1], t: vertex[2]

				int2 pixelCoords = make_int2(pFrag.x, pFrag.y);
				int pixelID = pixelCoords.x + pixelCoords.y * uniforms.width;

				pixelID = max(pixelID, 0);
				pixelID = min(pixelID, int(uniforms.width * uniforms.height));

				if( (s >= 0.0) && (t >= 0.0) && (s + t <= 1.0) )
				{

					uint8_t* v0_rgba = (uint8_t*)&triangles->colors[i0];
					uint8_t* v1_rgba = (uint8_t*)&triangles->colors[i1];
					uint8_t* v2_rgba = (uint8_t*)&triangles->colors[i2];

					float2 v0_uv = triangles->uvs[i0];
					float2 v1_uv = triangles->uvs[i1];
					float2 v2_uv = triangles->uvs[i2];
					float2 uv = {
						v * v0_uv.x + s * v1_uv.x + t * v2_uv.x,
						v * v0_uv.y + s * v1_uv.y + t * v2_uv.y
					};

					uint32_t color;
					uint8_t* rgb = (uint8_t*)&color;

					// { // color by vertex color
					// 	rgb[0] = v * v0_rgba[0] + s * v1_rgba[0] + t * v2_rgba[0];
					// 	rgb[1] = v * v0_rgba[1] + s * v1_rgba[1] + t * v2_rgba[1];
					// 	rgb[2] = v * v0_rgba[2] + s * v1_rgba[2] + t * v2_rgba[2];
					// }

					if(colorMode == COLORMODE_TEXTURE && texture != nullptr){
						// color by texture
						int tx = int(uv.x * texture->width) % texture->width;
						int ty = int(uv.y * texture->height) % texture->height;
						ty = texture->height - ty;

						int texelIndex = tx + texture->width * ty;
						uint32_t texel = texture->data[texelIndex];
						uint8_t* texel_rgb = (uint8_t*)&texel;

						if(uniforms.sampleMode == SAMPLEMODE_NEAREST){
							color = sample_nearest(uv, texture);
						}else if(uniforms.sampleMode == SAMPLEMODE_LINEAR){
							color = sample_linear(uv, texture);
						}
					}else if(colorMode == COLORMODE_UV && triangles->uvs != nullptr){
						rgb[0] = 255.0f * uv.x;
						rgb[1] = 255.0f * uv.y;
						rgb[2] = 0;
					}else if(colorMode == COLORMODE_TRIANGLE_ID){
						color = sh_triangleIndex * 123456;
					}else{
						color = sh_triangleIndex * 123456;
					}

					// try coloring by time
					// uint64_t nanotime;
					// asm volatile("mov.u64 %0, %%globaltimer;" : "=l"(nanotime));
					// color = (nanotime - nanotime_start) % 0x00ffffffull;

					float depth = v * p0.w + s * p1.w + t * p2.w;
					uint64_t udepth = *((uint32_t*)&depth);
					uint64_t pixel = (udepth << 32ull) | color;

					atomicMin(&framebuffer[pixelID], pixel);
				}

				numProcessedSamples++;
			}


		}
	}
}

extern "C" __global__
void kernel(
	const Uniforms _uniforms,
	unsigned int* buffer,
	cudaSurfaceObject_t gl_colorbuffer,
	uint32_t numTriangles,
	float3* positions,
	float2* uvs,
	uint32_t* colors,
	uint32_t* textureData
){
	auto grid = cg::this_grid();
	auto block = cg::this_thread_block();

	asm volatile("mov.u64 %0, %%globaltimer;" : "=l"(nanotime_start));

	uniforms = _uniforms;

	Allocator _allocator(buffer, 0);
	allocator = &_allocator;

	// allocate framebuffer memory
	int framebufferSize = int(uniforms.width) * int(uniforms.height) * sizeof(uint64_t);
	uint64_t* framebuffer = allocator->alloc<uint64_t*>(framebufferSize);

	// clear framebuffer
	processRange(0, uniforms.width * uniforms.height, [&](int pixelIndex){
		// depth:            7f800000 (Infinity)
		// background color: 00332211 (aabbggrr)
		framebuffer[pixelIndex] = 0x7f800000'00332211ull;;
	});

	grid.sync();

	{ // generate and draw a ground plane
		int cells = 20;
		int numTriangles     = cells * cells * 2;
		int numVertices      = 3 * numTriangles;
		Triangles* triangles = allocator->alloc<Triangles*>(sizeof(Triangles));
		triangles->positions = allocator->alloc<float3*  >(sizeof(float3) * numVertices);
		triangles->uvs       = allocator->alloc<float2*  >(sizeof(float2) * numVertices);
		triangles->colors    = allocator->alloc<uint32_t*>(sizeof(uint32_t) * numVertices);

		triangles->numTriangles = numTriangles;
		
		processRange(0, cells * cells, [&](int cellIndex){

			int cx = cellIndex % cells;
			int cy = cellIndex / cells;

			float u0 = float(cx + 0) / float(cells);
			float v0 = float(cy + 0) / float(cells);
			float u1 = float(cx + 1) / float(cells);
			float v1 = float(cy + 1) / float(cells);

			int offset = 6 * cellIndex;

			uint32_t color = 0;
			uint8_t* rgb = (uint8_t*)&color;
			rgb[0] = 255.0f * u0;
			rgb[1] = 255.0f * v0;
			rgb[2] = 0;

			triangles->positions[offset + 0] = {2.0 * u0 - 1.0, -0.7, 2.0 * v0 - 1.0};
			triangles->positions[offset + 2] = {2.0 * u1 - 1.0, -0.7, 2.0 * v0 - 1.0};
			triangles->positions[offset + 1] = {2.0 * u1 - 1.0, -0.7, 2.0 * v1 - 1.0};
			triangles->colors[offset + 0]    = color;
			triangles->colors[offset + 2]    = color;
			triangles->colors[offset + 1]    = color;

			triangles->positions[offset + 3] = {2.0 * u0 - 1.0, -0.7, 2.0 * v0 - 1.0};
			triangles->positions[offset + 5] = {2.0 * u1 - 1.0, -0.7, 2.0 * v1 - 1.0};
			triangles->positions[offset + 4] = {2.0 * u0 - 1.0, -0.7, 2.0 * v1 - 1.0};
			triangles->colors[offset + 3]    = color;
			triangles->colors[offset + 5]    = color;
			triangles->colors[offset + 4]    = color;
		});
		
		RasterizationSettings settings;
		settings.texture = nullptr;
		settings.colorMode = COLORMODE_TRIANGLE_ID;

		rasterizeTriangles(triangles, framebuffer, settings);
	}

	grid.sync();

	{ // draw the triangle mesh that was passed to this kernel
		Triangles* triangles = allocator->alloc<Triangles*>(sizeof(Triangles));
		triangles->numTriangles = numTriangles;

		triangles->positions = positions;
		triangles->uvs = uvs;
		triangles->colors = colors;

		Texture texture;
		texture.width  = 1024;
		texture.height = 1024;
		texture.data   = textureData;

		RasterizationSettings settings;
		settings.texture = &texture;
		settings.colorMode = uniforms.colorMode;

		rasterizeTriangles(triangles, framebuffer, settings);
	}

	grid.sync();

	// transfer framebuffer to opengl texture
	processRange(0, uniforms.width * uniforms.height, [&](int pixelIndex){

		int x = pixelIndex % int(uniforms.width);
		int y = pixelIndex / int(uniforms.width);

		uint64_t encoded = framebuffer[pixelIndex];
		uint32_t color = encoded & 0xffffffffull;

		surf2Dwrite(color, gl_colorbuffer, x * 4, y);
	});


}
