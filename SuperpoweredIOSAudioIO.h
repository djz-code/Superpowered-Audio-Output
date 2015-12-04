#import <AVFoundation/AVAudioSession.h>


@protocol SuperpoweredIOSAudioIODelegate;


/**
 @brief Handles all audio session, audio lifecycle (interruptions), output, buffer size, samplerate and routing headaches.
 
 @warning All methods and setters should be called on the main thread only!
 */
@interface SuperpoweredIOSAudioIO: NSObject {
    int preferredBufferSizeMs;
}

/** @brief The preferred buffer size. Recommended: 12. */
@property (nonatomic, assign) int preferredBufferSizeMs;
/** @brief Save battery if output is silence and the app runs in background mode. True by default. */

/**
 @brief Creates the audio output instance.
  
 @param delegate The object fully implementing the SuperpoweredIOSAudioIODelegate protocol. Not retained.
 @param preferredBufferSize The initial value for preferredBufferSizeMs. 12 is good for every iOS device (512 samples).
 @param preferredMinimumSamplerate The preferred minimum sample rate. 44100 or 48000 are recommended for good sound quality.
 @param audioSessionCategory The audio session category. Audio input is enabled for the appropriate categories only!
 @param channels The number of channels in the audio processing callback.
 */
- (id)initWithDelegate:(id<SuperpoweredIOSAudioIODelegate>)delegate preferredBufferSize:(unsigned int)preferredBufferSize preferredMinimumSamplerate:(unsigned int)preferredMinimumSamplerate audioSessionCategory:(NSString *)audioSessionCategory channels:(int)channels;

/**
 @brief Starts audio processing.
 
 @return True if successful, false if failed.
 */
- (bool)start;

/**
 @brief Stops audio processing.
 */
- (void)stop;

@end


/**
 @brief You must implement this protocol to make SuperpoweredIOSAudioIO work.
 */
@protocol SuperpoweredIOSAudioIODelegate

/**
 @brief The audio session may be interrupted by a phone call, etc. This method is called on the main thread when this happens.
 */
- (void)interruptionStarted;

/**
 @brief The audio session may be interrupted by a phone call, etc. This method is called on the main thread when audio resumes.
 */
- (void)interruptionEnded;

/**
 @brief Process audio here.
 
 @return Return false for no audio output (silence).
 
 @param buffers Input-output buffers.
 @param outputChannels The number of output channels.
 @param numberOfSamples The number of samples requested.
 @param samplerate The current sample rate in Hz.
 @param hostTime A mach timestamp, indicates when this chunk of audio will be passed to the audio output.
 
 @warning It's called on a high priority real-time audio thread, so please take care of blocking and processing time to prevent audio dropouts.
 */
- (bool)audioProcessingCallback:(float **)buffers outputChannels:(unsigned int)outputChannels numberOfSamples:(unsigned int)numberOfSamples samplerate:(unsigned int)samplerate hostTime:(UInt64)hostTime;

@end
