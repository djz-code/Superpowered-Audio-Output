#import "SuperpoweredIOSAudioIO.h"
#import <AudioToolbox/AudioToolbox.h>
#import <AudioUnit/AudioUnit.h>
#import <MediaPlayer/MediaPlayer.h>


// Initialization
@implementation SuperpoweredIOSAudioIO {
    id<SuperpoweredIOSAudioIODelegate>delegate;
    NSString *audioSessionCategory;
    AudioComponentInstance audioUnit;
    int numChannels, samplerate, preferredMinimumSamplerate;
    bool audioUnitRunning;
}

@synthesize preferredBufferSizeMs;

- (id)initWithDelegate:(NSObject<SuperpoweredIOSAudioIODelegate> *)d preferredBufferSize:(unsigned int)preferredBufferSize preferredMinimumSamplerate:(unsigned int)prefsamplerate audioSessionCategory:(NSString *)category channels:(int)channels {
    self = [super init];
    if (self) {
        numChannels = channels;
        audioSessionCategory = category;
        preferredBufferSizeMs = preferredBufferSize;
        preferredMinimumSamplerate = prefsamplerate;
        delegate = d;
        audioUnitRunning = false;
        samplerate = 0;
        audioUnit = NULL;

        [self resetAudio];

        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onMediaServerReset:) name:AVAudioSessionMediaServicesWereResetNotification object:[AVAudioSession sharedInstance]];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onAudioSessionInterrupted:) name:AVAudioSessionInterruptionNotification object:[AVAudioSession sharedInstance]];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onRouteChange:) name:AVAudioSessionRouteChangeNotification object:[AVAudioSession sharedInstance]];
    };
    return self;
}

- (void)dealloc {
    if (audioUnit != NULL) {
        AudioUnitUninitialize(audioUnit);
        AudioComponentInstanceDispose(audioUnit);
    };
    [[AVAudioSession sharedInstance] setActive:NO error:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

// App and audio session lifecycle
- (void)onMediaServerReset:(NSNotification *)notification { // The mediaserver daemon can die. Yes, it happens sometimes.
    if (![NSThread isMainThread]) [self performSelectorOnMainThread:@selector(onMediaServerReset:) withObject:nil waitUntilDone:NO];
    else {
        if (audioUnit) AudioOutputUnitStop(audioUnit);
        audioUnitRunning = false;
        [[AVAudioSession sharedInstance] setActive:NO error:nil];
        [self resetAudio];
        [self start];
    };
}

- (void)beginInterruption { // Phone call, etc.
    if (![NSThread isMainThread]) [self performSelectorOnMainThread:@selector(beginInterruption) withObject:nil waitUntilDone:NO];
    else {
        audioUnitRunning = false;
        if (audioUnit) AudioOutputUnitStop(audioUnit);
    };
}

- (void)endInterruption {
    if (audioUnitRunning) return;
    if (![NSThread isMainThread]) [self performSelectorOnMainThread:@selector(endInterruption) withObject:nil waitUntilDone:NO];
    else for (int n = 0; n < 2; n++) if ([[AVAudioSession sharedInstance] setActive:YES error:nil] && [self start]) { // Need to try twice sometimes. Don't know why.
        [delegate interruptionEnded];
        audioUnitRunning = true;
        break;
    };
}

- (void)endInterruptionWithFlags:(NSUInteger)flags {
    [self endInterruption];
}

- (void)startDelegateInterruption {
    [delegate interruptionStarted];
}

- (void)onAudioSessionInterrupted:(NSNotification *)notification {
    NSNumber *interruption = [notification.userInfo objectForKey:AVAudioSessionInterruptionTypeKey];
    if (interruption) switch ([interruption intValue]) {
        case AVAudioSessionInterruptionTypeBegan:
            if (audioUnitRunning) [self performSelectorOnMainThread:@selector(startDelegateInterruption) withObject:nil waitUntilDone:NO];
            [self beginInterruption];
            break;
        case AVAudioSessionInterruptionTypeEnded: [self endInterruption]; break;
    };
}

// Audio Session
- (void)onRouteChange:(NSNotification *)notification {
    if (![NSThread isMainThread]) {
        [self performSelectorOnMainThread:@selector(onRouteChange:) withObject:notification waitUntilDone:NO];
        return;
    };
    
    bool receiverAvailable = false, usbOrHDMIAvailable = false;
    for (AVAudioSessionPortDescription *port in [[[AVAudioSession sharedInstance] currentRoute] outputs]) {
        if ([port.portType isEqualToString:AVAudioSessionPortUSBAudio] || [port.portType isEqualToString:AVAudioSessionPortHDMI]) {
            usbOrHDMIAvailable = true;
            break;
        } else if ([port.portType isEqualToString:AVAudioSessionPortBuiltInReceiver]) receiverAvailable = true;
    };

    if (receiverAvailable && !usbOrHDMIAvailable) { // Comment this out if you would like to use the receiver instead.
        [[AVAudioSession sharedInstance] overrideOutputAudioPort:AVAudioSessionPortOverrideSpeaker error:nil];
        [self performSelectorOnMainThread:@selector(onRouteChange:) withObject:nil waitUntilDone:NO];
    };
}

- (void)setSamplerateAndBuffersize {
    if (samplerate > 0) {
        double sr = samplerate < preferredMinimumSamplerate ? preferredMinimumSamplerate : 0, current;
        current = [[AVAudioSession sharedInstance] preferredSampleRate];
        if (current != sr) {
            [[AVAudioSession sharedInstance] setPreferredSampleRate:sr error:NULL];
        };
    };
    [[AVAudioSession sharedInstance] setPreferredIOBufferDuration:double(preferredBufferSizeMs) * 0.001 error:NULL];
}

- (void)resetAudio {
    if (audioUnit != NULL) {
        AudioUnitUninitialize(audioUnit);
        AudioComponentInstanceDispose(audioUnit);
        audioUnit = NULL;
    };

    [[AVAudioSession sharedInstance] setCategory:audioSessionCategory error:NULL];
    [[AVAudioSession sharedInstance] setMode:AVAudioSessionModeDefault error:NULL];
    [self setSamplerateAndBuffersize];
    [[AVAudioSession sharedInstance] setActive:YES error:NULL];

    audioUnit = [self createRemoteIO];
    [self onRouteChange:nil];
}

// RemoteIO
static void streamFormatChangedCallback(void *inRefCon, AudioUnit inUnit, AudioUnitPropertyID inID, AudioUnitScope inScope, AudioUnitElement inElement) {
    if ((inScope == kAudioUnitScope_Output) && (inElement == 0)) {
        UInt32 size = 0;
        AudioUnitGetPropertyInfo(inUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &size, NULL);
        AudioStreamBasicDescription format;
        AudioUnitGetProperty(inUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &format, &size);
        SuperpoweredIOSAudioIO *self = (__bridge SuperpoweredIOSAudioIO *)inRefCon;
        self->samplerate = (int)format.mSampleRate;
        [self performSelectorOnMainThread:@selector(setSamplerateAndBuffersize) withObject:nil waitUntilDone:NO];
    };
}

static int x = 0;

static OSStatus audioProcessingCallback(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList *ioData) {
    SuperpoweredIOSAudioIO *self = (__bridge SuperpoweredIOSAudioIO *)inRefCon;

    div_t d = div(inNumberFrames, 8);
    if ((d.rem != 0) || (inNumberFrames < 32) || (inNumberFrames > 512) || (ioData->mNumberBuffers != self->numChannels)) {
        return kAudioUnitErr_InvalidParameter;
    };

    float *bufs[self->numChannels];
    for (int n = 0; n < self->numChannels; n++) bufs[n] = (float *)ioData->mBuffers[n].mData;
    bool silence = ![self->delegate audioProcessingCallback:bufs outputChannels:self->numChannels numberOfSamples:inNumberFrames samplerate:self->samplerate hostTime:inTimeStamp->mHostTime];

    if (silence) { // Despite of ioActionFlags, it outputs garbage sometimes, so must zero the buffers:
        *ioActionFlags |= kAudioUnitRenderAction_OutputIsSilence;
        for (unsigned char n = 0; n < ioData->mNumberBuffers; n++) memset(ioData->mBuffers[n].mData, 0, ioData->mBuffers[n].mDataByteSize);
    } else {
        bool bullshit = false;

        for (int j = 0; j < inNumberFrames; j++) {
            float value = bufs[0][j];
            if (value < -1 || value > 1) {
                bullshit = true;
                x++;
                break;
            }
        }

        if (bullshit) {
//            for (int j = 0; j < inNumberFrames; j++) {
//                float value = bufs[0][j];
//                int y = x;
//                dispatch_async(dispatch_get_main_queue(), ^{
//                    printf("%03d %03d %03f\n", y, j, value);
//                });
//            }

            *ioActionFlags |= kAudioUnitRenderAction_OutputIsSilence;
            for (unsigned char n = 0; n < ioData->mNumberBuffers; n++) memset(ioData->mBuffers[n].mData, 0, ioData->mBuffers[n].mDataByteSize);
        }
    }

    return noErr;
}

- (AudioUnit)createRemoteIO {
    AudioUnit au;

    AudioComponentDescription desc;
	desc.componentType = kAudioUnitType_Output;
	desc.componentSubType = kAudioUnitSubType_RemoteIO;
	desc.componentFlags = 0;
	desc.componentFlagsMask = 0;
	desc.componentManufacturer = kAudioUnitManufacturer_Apple;
	AudioComponent component = AudioComponentFindNext(NULL, &desc);
	if (AudioComponentInstanceNew(component, &au) != 0) return NULL;

	UInt32 value = 1;
	if (AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &value, sizeof(value))) { AudioComponentInstanceDispose(au); return NULL; };
    value = 0;
	if (AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &value, sizeof(value))) { AudioComponentInstanceDispose(au); return NULL; };

    AudioUnitAddPropertyListener(au, kAudioUnitProperty_StreamFormat, streamFormatChangedCallback, (__bridge void *)self);

    UInt32 size = 0;
    AudioUnitGetPropertyInfo(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &size, NULL);
    AudioStreamBasicDescription format;
    AudioUnitGetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &format, &size);

    samplerate = (int)format.mSampleRate;
    [self setSamplerateAndBuffersize];

	format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagsNativeEndian;
    format.mBitsPerChannel = 32;
	format.mFramesPerPacket = 1;
    format.mBytesPerFrame = 4;
    format.mBytesPerPacket = 4;
    format.mChannelsPerFrame = numChannels;
    if (AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, sizeof(format))) { AudioComponentInstanceDispose(au); return NULL; };
    if (AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &format, sizeof(format))) { AudioComponentInstanceDispose(au); return NULL; };
    
	AURenderCallbackStruct callbackStruct;
	callbackStruct.inputProc = audioProcessingCallback;
	callbackStruct.inputProcRefCon = (__bridge void *)self;
	if (AudioUnitSetProperty(au, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callbackStruct, sizeof(callbackStruct))) { AudioComponentInstanceDispose(au); return NULL; };
    
	AudioUnitInitialize(au);
    return au;
}

// Public methods
- (bool)start {
    if (audioUnit == NULL) return false;
    if (AudioOutputUnitStart(audioUnit)) return false;
    audioUnitRunning = true;
    return true;
}

- (void)stop {
    if (audioUnit != NULL) AudioOutputUnitStop(audioUnit);
    x = 0;
}

@end
