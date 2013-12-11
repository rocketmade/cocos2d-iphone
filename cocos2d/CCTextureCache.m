/*
 * cocos2d for iPhone: http://www.cocos2d-iphone.org
 *
 * Copyright (c) 2008-2010 Ricardo Quesada
 * Copyright (c) 2011 Zynga Inc.
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
 *
 */

#import "ccMacros.h"
#import "Platforms/CCGL.h"
#import "CCTextureCache.h"
#import "CCTexture.h"
#import "CCTexturePVR.h"
#import "CCConfiguration.h"
#import "CCDirector.h"
#import "ccConfig.h"
#import "ccTypes.h"

#import "Support/CCFileUtils.h"
#import "Support/NSThread+performBlock.h"

#import <objc/message.h>


#ifdef __CC_PLATFORM_MAC
#import "Platforms/Mac/CCDirectorMac.h"
#endif

#import "CCTexture_Private.h"

// needed for CCCallFuncO in Mac-display_link version
//#import "CCActionManager.h"
//#import "CCActionInstant.h"

#ifdef __CC_PLATFORM_IOS
static EAGLContext *_auxGLcontext = nil;
#elif defined(__CC_PLATFORM_MAC)
static NSOpenGLContext *_auxGLcontext = nil;
#endif

@implementation CCTextureCache

#pragma mark TextureCache - Alloc, Init & Dealloc
static CCTextureCache *sharedTextureCache;

+ (CCTextureCache *)sharedTextureCache
{
	if (!sharedTextureCache)
		sharedTextureCache = [[self alloc] init];

	return sharedTextureCache;
}

+(id)alloc
{
	NSAssert(sharedTextureCache == nil, @"Attempted to allocate a second instance of a singleton.");
	return [super alloc];
}

+(void)purgeSharedTextureCache
{
	sharedTextureCache = nil;
}

-(id) init
{
	if( (self=[super init]) ) {
		_textures = [NSMutableDictionary dictionaryWithCapacity: 10];

		// init "global" stuff
		_loadingQueue = dispatch_queue_create("org.cocos2d.texturecacheloading", NULL);
		_dictQueue = dispatch_queue_create("org.cocos2d.texturecachedict", NULL);

		CCGLView *view = (CCGLView*)[[CCDirector sharedDirector] view];
		NSAssert(view, @"Do not initialize the TextureCache before the Director");

#ifdef __CC_PLATFORM_IOS
		_auxGLcontext = [[EAGLContext alloc]
						 initWithAPI:kEAGLRenderingAPIOpenGLES2
						 sharegroup:[[view context] sharegroup]];

#elif defined(__CC_PLATFORM_MAC)
		NSOpenGLPixelFormat *pf = [view pixelFormat];
		NSOpenGLContext *share = [view openGLContext];

		_auxGLcontext = [[NSOpenGLContext alloc] initWithFormat:pf shareContext:share];

#endif // __CC_PLATFORM_MAC

		NSAssert( _auxGLcontext, @"TextureCache: Could not create EAGL context");

	}

	return self;
}

- (NSString*) description
{
	__block NSString *desc = nil;
	dispatch_sync(_dictQueue, ^{
		desc = [NSString stringWithFormat:@"<%@ = %p | num of textures =  %lu | keys: %@>",
			[self class],
			self,
			(unsigned long)[_textures count],
			[_textures allKeys]
			];
	});
	return desc;
}

-(void) dealloc
{
	CCLOGINFO(@"cocos2d: deallocing %@", self);
    
	_auxGLcontext = nil;
	sharedTextureCache = nil;
    
	dispatch_release(_loadingQueue);
	dispatch_release(_dictQueue);
    
}

#pragma mark TextureCache - Add Images

-(void) addImageAsync: (NSString*)path target:(id)target selector:(SEL)selector
{
	NSAssert(path != nil, @"TextureCache: fileimage MUST not be nill");
	NSAssert(target != nil, @"TextureCache: target can't be nil");
	NSAssert(selector != NULL, @"TextureCache: selector can't be NULL");

	// remove possible -HD suffix to prevent caching the same image twice (issue #1040)
	CCFileUtils *fileUtils = [CCFileUtils sharedFileUtils];
	path = [fileUtils standarizePath:path];

	// optimization
	__block CCTexture * tex;
		
	dispatch_sync(_dictQueue, ^{
		tex = [_textures objectForKey:path];
	});

	if(tex) {
        objc_msgSend(target, selector, tex);
		return;
	}

	// dispatch it serially
	dispatch_async(_loadingQueue, ^{

		CCTexture *texture;

#ifdef __CC_PLATFORM_IOS
		if( [EAGLContext setCurrentContext:_auxGLcontext] ) {

			// load / create the texture
			texture = [self addImage:path];

			glFlush();

			// callback should be executed in cocos2d thread
			[target performSelector:selector onThread:[[CCDirector sharedDirector] runningThread] withObject:texture waitUntilDone:NO];

			[EAGLContext setCurrentContext:nil];
		} else {
			CCLOG(@"cocos2d: ERROR: TetureCache: Could not set EAGLContext");
		}

#elif defined(__CC_PLATFORM_MAC)

		[_auxGLcontext makeCurrentContext];

		// load / create the texture
		texture = [self addImage:path];

		glFlush();

		// callback should be executed in cocos2d thread
		[target performSelector:selector onThread:[[CCDirector sharedDirector] runningThread] withObject:texture waitUntilDone:NO];

		[NSOpenGLContext clearCurrentContext];

#endif // __CC_PLATFORM_MAC

	});
}

-(void) addImageAsync:(NSString*)path withBlock:(void(^)(CCTexture *tex))block
{
	NSAssert(path != nil, @"TextureCache: fileimage MUST not be nil");

	// remove possible -HD suffix to prevent caching the same image twice (issue #1040)
	CCFileUtils *fileUtils = [CCFileUtils sharedFileUtils];
	path = [fileUtils standarizePath:path];

	// optimization
	__block CCTexture * tex;

	dispatch_sync(_dictQueue, ^{
		tex = [_textures objectForKey:path];
	});

	if(tex) {
		block(tex);
		return;
	}

	// dispatch it serially
	dispatch_async( _loadingQueue, ^{

		CCTexture *texture;

#ifdef __CC_PLATFORM_IOS
		if( [EAGLContext setCurrentContext:_auxGLcontext] ) {

			// load / create the texture
			texture = [self addImage:path];

			glFlush();
            
            [EAGLContext setCurrentContext:nil];

			// callback should be executed in cocos2d thread
			NSThread *thread = [[CCDirector sharedDirector] runningThread];
			[thread performBlock:block withObject:texture waitUntilDone:NO];
        
		} else {
			CCLOG(@"cocos2d: ERROR: TetureCache: Could not set EAGLContext");
		}

#elif defined(__CC_PLATFORM_MAC)

		[_auxGLcontext makeCurrentContext];

		// load / create the texture
		texture = [self addImage:path];

		glFlush();
        
        [NSOpenGLContext clearCurrentContext];

		// callback should be executed in cocos2d thread
		NSThread *thread = [[CCDirector sharedDirector] runningThread];
		[thread performBlock:block withObject:texture waitUntilDone:NO];

#endif // __CC_PLATFORM_MAC

	});
}

#import "png.h"

static void
Premultiply(png_structp png, png_row_infop row_info, png_bytep row)
{
	int width = row_info->width;
	
	// Could be vectorized.
	if(row_info->channels == 4){
		for(int i=0; i<width; i++){
			png_byte alpha = row[i*4 + 3];
			row[i*4 + 0] = row[i*4 + 0]*alpha/255;
			row[i*4 + 1] = row[i*4 + 1]*alpha/255;
			row[i*4 + 2] = row[i*4 + 2]*alpha/255;
		}
	} else {
		for(int i=0; i<width; i++){
			png_byte alpha = row[i*2 + 1];
			row[i*2 + 0] = row[i*2 + 0]*alpha/255;
		}
	}
}

struct ProgressiveInfo {
	BOOL rgb, alpha, premultiply;
	
	png_uint_32 width, height;
	png_uint_32 row_bytes;
	
	// Final rescaled image.
	png_bytep pixels;
	png_uint_32 current_row;
};

static void
ProgressiveInfo(png_structp png, png_infop png_info)
{
	NSLog(@"Info");
	struct ProgressiveInfo *info = png_get_progressive_ptr(png);
	
	info->width = png_get_image_width(png, png_info);
	info->height = png_get_image_height(png, png_info);
	
	png_uint_32 bit_depth, color_type;
	bit_depth = png_get_bit_depth(png, png_info);
	color_type = png_get_color_type(png, png_info);
	
	if(color_type == PNG_COLOR_TYPE_GRAY && bit_depth < 8){
		png_set_expand_gray_1_2_4_to_8(png);
	}
	
	if (bit_depth == 16){
		png_set_strip_16(png);
	}
	
	if(info->rgb){
		if(color_type == PNG_COLOR_TYPE_PALETTE){
			png_set_palette_to_rgb(png);
		} else if(color_type == PNG_COLOR_TYPE_GRAY || color_type == PNG_COLOR_TYPE_GRAY_ALPHA){
			png_set_gray_to_rgb(png);
		}
	} else {
		NSCAssert(color_type != PNG_COLOR_TYPE_PALETTE, @"Paletted PNG to grayscale conversion not supported.");
		
		if(color_type == PNG_COLOR_TYPE_RGB || color_type == PNG_COLOR_TYPE_RGB_ALPHA){
			png_set_rgb_to_gray_fixed(png, 1, -1, -1);
		}
	}
	
	if(info->alpha){
		if(png_get_valid(png, png_info, PNG_INFO_tRNS)){
			png_set_tRNS_to_alpha(png);
		} else {
			png_set_filler(png, 0xff, PNG_FILLER_AFTER);
		}
	} else 	{
		if(color_type & PNG_COLOR_MASK_ALPHA){
			png_set_strip_alpha(png);
		}
	}
	
	if(info->premultiply){
		png_set_read_user_transform_fn(png, Premultiply);
	}
  
	png_read_update_info(png, png_info);
	
	info->row_bytes = png_get_rowbytes(png, png_info);
	info->pixels = malloc(info->row_bytes*info->height);
}

static void
ProgressiveRow(png_structp png, png_bytep rowPixels, png_uint_32 row, int pass)
{
	NSLog(@"row %d, pass: %d", row, pass);
	struct ProgressiveInfo *info = png_get_progressive_ptr(png);
	
	png_size_t row_bytes = info->row_bytes;
	memcpy(info->pixels + row*row_bytes, rowPixels, row_bytes);
}

static void
ProgressiveEnd(png_structp png, png_infop png_info)
{
	NSLog(@"End");
}

static NSDictionary *
LoadPNG(NSString *path, BOOL rgb, BOOL alpha, BOOL premultiply)
{
	FILE *file = fopen(path.UTF8String, "rb");
	NSCAssert(file, @"PNG file %@ could not be loaded.", path);
	
//	const NSUInteger PNG_SIG_BYTES = 8;
//	png_byte header[PNG_SIG_BYTES];
//	fread(header, 1, PNG_SIG_BYTES, file);
//	NSCAssert(!png_sig_cmp(header, 0, PNG_SIG_BYTES), @"Bad PNG header on %@", path);
	
	png_structp png = png_create_read_struct(PNG_LIBPNG_VER_STRING, NULL, NULL, NULL);
	NSCAssert(png, @"Error creating PNG read struct");
	
	png_infop png_info = png_create_info_struct(png);
	NSCAssert(png_info, @"libPNG error");
	
	png_infop end_info = png_create_info_struct(png);
	NSCAssert(end_info, @"libPNG error");
	
	NSCAssert(!setjmp(png_jmpbuf(png)), @"PNG file %@ could not be loaded.", path);
	
//	png_init_io(png, file);
//	png_set_sig_bytes(png, PNG_SIG_BYTES);
//	png_read_info(png, info);
	
	struct ProgressiveInfo info = {};
	info.rgb = rgb;
	info.alpha = alpha;
	info.premultiply = premultiply;
	
	png_set_progressive_read_fn(png, &info, ProgressiveInfo, ProgressiveRow, ProgressiveEnd);
	
	// Read 4k at a time. (page size?)
	const png_size_t buffer_size = 4*1024;
	png_byte buffer[buffer_size];
	
	while(!feof(file)){
		png_size_t buffered = fread(buffer, 1, buffer_size, file);
		
		// TODO Decrypt buffer here.
		
		// Pass the data on to libpng.
		png_process_data(png, png_info, buffer, buffered);
	}
		
	png_destroy_read_struct(&png, &png_info, &end_info);
	fclose(file);
	
	return @{
		@"width": @(info.width),
		@"height": @(info.height),
		@"data": [NSData dataWithBytesNoCopy:info.pixels length:info.width*info.row_bytes freeWhenDone:YES],
	};
}

-(CCTexture*) addImage: (NSString*) path
{
	NSAssert(path != nil, @"TextureCache: fileimage MUST not be nil");

	// remove possible -HD suffix to prevent caching the same image twice (issue #1040)
	CCFileUtils *fileUtils = [CCFileUtils sharedFileUtils];
	path = [fileUtils standarizePath:path];

	__block CCTexture * tex = nil;

	dispatch_sync(_dictQueue, ^{
		tex = [_textures objectForKey: path];
	});

	if( ! tex ) {

		CGFloat contentScale;
		NSString *fullpath = [fileUtils fullPathForFilename:path contentScale:&contentScale];
		if( ! fullpath ) {
			CCLOG(@"cocos2d: Couldn't find file:%@", path);
			return nil;
		}

		NSString *lowerCase = [fullpath lowercaseString];

		// all images are handled by UIKit/AppKit except PVR extension that is handled by cocos2d's handler

		if ( [lowerCase hasSuffix:@".pvr"] || [lowerCase hasSuffix:@".pvr.gz"] || [lowerCase hasSuffix:@".pvr.ccz"] )
			tex = [self addPVRImage:path];

#ifdef __CC_PLATFORM_IOS

		else {
			NSDictionary *image = LoadPNG(fullpath, YES, YES, YES);
			NSUInteger w = [image[@"width"] integerValue], h = [image[@"height"] integerValue];
			tex = [[CCTexture alloc] initWithData:[image[@"data"] bytes] pixelFormat:CCTexturePixelFormat_RGBA8888 pixelsWide:w pixelsHigh:h contentSizeInPixels:CGSizeMake(w, h) contentScale:contentScale];
			
//			UIImage *image = [[UIImage alloc] initWithContentsOfFile:fullpath];
//			tex = [[CCTexture alloc] initWithCGImage:image.CGImage contentScale:contentScale];
      
			if( tex ){
				dispatch_sync(_dictQueue, ^{
					[_textures setObject: tex forKey:path];
				});
			}else{
				CCLOG(@"cocos2d: Couldn't create texture for file:%@ in CCTextureCache", path);
			}
		}


#elif defined(__CC_PLATFORM_MAC)
		else {

			NSData *data = [[NSData alloc] initWithContentsOfFile:fullpath];
			NSBitmapImageRep *image = [[NSBitmapImageRep alloc] initWithData:data];
			tex = [ [CCTexture alloc] initWithCGImage:[image CGImage] contentScale:contentScale];


			if( tex ){
				dispatch_sync(_dictQueue, ^{
					[_textures setObject: tex forKey:path];
				});
			}else{
				CCLOG(@"cocos2d: Couldn't create texture for file:%@ in CCTextureCache", path);
			}

			// autorelease prevents possible crash in multithreaded environments
			//[tex autorelease];
		}
#endif // __CC_PLATFORM_MAC

	}

	return tex;
}


-(CCTexture*) addCGImage: (CGImageRef) imageref forKey: (NSString *)key
{
	NSAssert(imageref != nil, @"TextureCache: image MUST not be nill");

	__block CCTexture * tex = nil;

	// If key is nil, then create a new texture each time
	if( key ) {
		dispatch_sync(_dictQueue, ^{
			tex = [_textures objectForKey:key];
		});
		if(tex)
			return tex;
	}

	tex = [[CCTexture alloc] initWithCGImage:imageref contentScale:1.0];

	if(tex && key){
		dispatch_sync(_dictQueue, ^{
			[_textures setObject: tex forKey:key];
		});
	}else{
		CCLOG(@"cocos2d: Couldn't add CGImage in CCTextureCache");
	}

	return tex;
}

#pragma mark TextureCache - Remove

-(void) removeAllTextures
{
	dispatch_sync(_dictQueue, ^{
		[_textures removeAllObjects];
	});
}

-(void) removeUnusedTextures
{
//	dispatch_sync(_dictQueue, ^{
//		NSArray *keys = [_textures allKeys];
//		for( id key in keys ) {
//			id value = [_textures objectForKey:key];
//			if( CFGetRetainCount((CFTypeRef) value) == 1 ) {
//				CCLOG(@"cocos2d: CCTextureCache: removing unused texture: %@", key);
//                NSLog(@"Remove!");
//				[_textures removeObjectForKey:key];
//			}
//		}
//	});
}

-(void) removeTexture: (CCTexture*) tex
{
	if( ! tex )
		return;

	dispatch_sync(_dictQueue, ^{
		NSArray *keys = [_textures allKeysForObject:tex];

		for( NSUInteger i = 0; i < [keys count]; i++ )
			[_textures removeObjectForKey:[keys objectAtIndex:i]];
	});
}

-(void) removeTextureForKey:(NSString*)name
{
	if( ! name )
		return;

	dispatch_sync(_dictQueue, ^{
		[_textures removeObjectForKey:name];
	});
}

#pragma mark TextureCache - Get
- (CCTexture *)textureForKey:(NSString *)key
{
	__block CCTexture *tex = nil;

	dispatch_sync(_dictQueue, ^{
		tex = [_textures objectForKey:key];
	});

	return tex;
}

@end


@implementation CCTextureCache (PVRSupport)

-(CCTexture*) addPVRImage:(NSString*)path
{
	NSAssert(path != nil, @"TextureCache: fileimage MUST not be nill");

	// remove possible -HD suffix to prevent caching the same image twice (issue #1040)
	CCFileUtils *fileUtils = [CCFileUtils sharedFileUtils];
	path = [fileUtils standarizePath:path];

	__block CCTexture * tex;
	
	dispatch_sync(_dictQueue, ^{
		tex = [_textures objectForKey:path];
	});

	if(tex) {
		return tex;
	}

	tex = [[CCTexture alloc] initWithPVRFile: path];
	if( tex ){
		dispatch_sync(_dictQueue, ^{
			[_textures setObject: tex forKey:path];
		});
	}else{
		CCLOG(@"cocos2d: Couldn't add PVRImage:%@ in CCTextureCache",path);
	}

	return tex;
}

@end


@implementation CCTextureCache (Debug)

-(void) dumpCachedTextureInfo
{
	__block NSUInteger count = 0;
	__block NSUInteger totalBytes = 0;

	dispatch_sync(_dictQueue, ^{
		for (NSString* texKey in _textures) {
			CCTexture* tex = [_textures objectForKey:texKey];
			NSUInteger bpp = [tex bitsPerPixelForFormat];
			// Each texture takes up width * height * bytesPerPixel bytes.
			NSUInteger bytes = tex.pixelWidth * tex.pixelHeight * bpp / 8;
			totalBytes += bytes;
			count++;
			NSLog( @"cocos2d: \"%@\"\tid=%lu\t%lu x %lu\t@ %ld bpp =>\t%lu KB",
				  texKey,
				  (long)tex.name,
				  (long)tex.pixelWidth,
				  (long)tex.pixelHeight,
				  (long)bpp,
				  (long)bytes / 1024 );
		}
	});
	NSLog( @"cocos2d: CCTextureCache dumpDebugInfo:\t%ld textures,\tfor %lu KB (%.2f MB)", (long)count, (long)totalBytes / 1024, totalBytes / (1024.0f*1024.0f));
}

@end
