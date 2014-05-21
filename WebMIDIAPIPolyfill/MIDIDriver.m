/*
 
 Copyright 2014 Takashi Mizuhiki
 
 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at
 
 http://www.apache.org/licenses/LICENSE-2.0
 
 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
 
 */

#import <mach/mach_time.h>

#import "MIDIDriver.h"
#import "MIDIParser.h"

@interface MIDIDriver () {
    NSArray *_parsers;
    mach_timebase_info_data_t _base;
    
    NSArray *_destinationEndpointIDs;
    NSArray *_sourceEndpointIDs;
}

@end

@implementation MIDIDriver

#pragma mark -
#pragma mark API

- (void)sendMessage:(NSData *)data toDestinationIndex:(ItemCount)index deltatime:(float)deltatime_ms
{
    MIDIEndpointRef endpoint = MIDIGetDestination(index);
    MIDITimeStamp timestamp = mach_absolute_time() + deltatime_ms * 1000000 /* ns */ * _base.denom / _base.numer;

    Byte buffer[sizeof(MIDIPacketList) + [data length]];
    MIDIPacketList *packetList = (MIDIPacketList *)buffer;
    MIDIPacket *packet = MIDIPacketListInit(packetList);
    packet = MIDIPacketListAdd(packetList, sizeof(buffer), packet, timestamp, [data length], [data bytes]);
    
    MIDISend(outputPortRef, endpoint, packetList);

    return;
}

#pragma mark -
#pragma mark MIDIParser delegate

- (void)midiParser:(MIDIParser *)parser recvMessage:(uint8_t *)message length:(uint32_t)length timestamp:(uint64_t)timestamp
{
    NSData *data = [[NSData alloc] initWithBytes:message length:length];
    
    ItemCount index = [_parsers indexOfObject:parser];

    dispatch_async(dispatch_get_main_queue(), ^{
        if (_onMessageReceived) {
            _onMessageReceived(index, data, timestamp);
        }
    });    
}

static void MyMIDIInputProc(const MIDIPacketList *pktlist, void *readProcRefCon, void *srcConnRefCon)
{
    MIDIParser *parser = (__bridge MIDIParser *)srcConnRefCon;
    
    MIDIPacket *packet = (MIDIPacket *)&(pktlist->packet[0]);
    UInt32 packetCount = pktlist->numPackets;

    for (NSInteger i = 0; i < packetCount; i++) {
        [parser setMessage:packet->data length:packet->length timestamp:packet->timeStamp];
        packet = MIDIPacketNext(packet);
    }
}

static void MyMIDINotifyProc(const MIDINotification *notification, void *refCon)
{
    MIDIDriver *myself = (__bridge MIDIDriver *)refCon;
    [myself onMIDINotification:notification];
}

- (void)onMIDINotification:(const MIDINotification *)notification
{
    switch (notification->messageID) {
        case kMIDIMsgSetupChanged:
            [self disposeMIDIInPort];
            [self disposeMIDIOutPort];
            [self createMIDIInPort];
            [self createMIDIOutPort];
            break;
            
        case kMIDIMsgObjectAdded:
            {
                MIDIObjectAddRemoveNotification *n = (MIDIObjectAddRemoveNotification *)notification;
                switch (n->childType) {
                    case kMIDIObjectType_Destination:
                        break;
                    case kMIDIObjectType_Source:
                        break;
                        
                    default:
                        break;
                }
            }
            break;
            
        case kMIDIMsgObjectRemoved:
            {
                MIDIObjectAddRemoveNotification *n = (MIDIObjectAddRemoveNotification *)notification;
                
                MIDIEndpointRef endpointRef = (MIDIEndpointRef)n->child;
                SInt32 uniqueId;
                MIDIObjectGetIntegerProperty(endpointRef, kMIDIPropertyUniqueID, &uniqueId);
                
                switch (n->childType) {
                    case kMIDIObjectType_Destination:
                        {
                            NSUInteger index = [_destinationEndpointIDs indexOfObject:[NSNumber numberWithInt:uniqueId]];
                            NSAssert(index != NSNotFound, @"Removed unknown MIDI destination");
                            if (_onDestinationPortRemoved) {
                                _onDestinationPortRemoved(index);
                            }
                        }
                        break;
                    
                    case kMIDIObjectType_Source:
                        {
                            NSUInteger index = [_sourceEndpointIDs indexOfObject:[NSNumber numberWithInt:uniqueId]];
                            NSAssert(index != NSNotFound, @"Removed unknown MIDI source");
                            if (_onSourcePortRemoved) {
                                _onSourcePortRemoved(index);
                            }
                        }
                        break;
                    
                    default:
                        break;
                }
            }
            break;
            
        default:
            break;
    }
}

- (BOOL)createMIDIInPort
{
    OSStatus err;
    
    NSString *inputPortName = @"inputPort";
    err = MIDIInputPortCreate(clientRef, (__bridge CFStringRef)inputPortName, MyMIDIInputProc, (__bridge void *)(self), &inputPortRef);
    if (err != noErr) {
        NSLog(@"MIDIInputPortCreate err = %d", (int)err);
        return NO;
    }
    
    // Get MIDI IN endpoints and connect them to the MIDI port.
    ItemCount sourceCount = MIDIGetNumberOfSources();
    NSMutableArray *parsers = [NSMutableArray arrayWithCapacity:sourceCount];
    NSMutableArray *sourceEndpointIDs = [NSMutableArray arrayWithCapacity:sourceCount];

    for (ItemCount i = 0; i < sourceCount; i++) {
        MIDIParser *parser = [[MIDIParser alloc] init];
        parser.delegate = self;
        [parsers addObject:parser];
        
        MIDIEndpointRef endpointRef = MIDIGetSource(i);
        err = MIDIPortConnectSource(inputPortRef, endpointRef, (__bridge void *)parser);
        
        //
        SInt32 uniqueId;
        MIDIObjectGetIntegerProperty(endpointRef, kMIDIPropertyUniqueID, &uniqueId);
        
        [sourceEndpointIDs addObject:[NSNumber numberWithInt:uniqueId]];
    }
    
    _parsers = parsers;
    _sourceEndpointIDs = sourceEndpointIDs;

    return YES;
}

- (BOOL)createMIDIOutPort
{
    OSStatus err;
    
    NSString *outputPortName = @"outputPort";
    err = MIDIOutputPortCreate(clientRef, (__bridge CFStringRef)outputPortName, &outputPortRef);
    if (err != noErr) {
        NSLog(@"MIDIOutputPortCreate err = %d", (int)err);
        return NO;
    }

    ItemCount destinationCount = MIDIGetNumberOfDestinations();
    NSMutableArray *destinationEndpointIDs = [NSMutableArray arrayWithCapacity:destinationCount];
    for (ItemCount i = 0; i < destinationCount; i++) {
        MIDIEndpointRef endpointRef = MIDIGetDestination(i);

        SInt32 uniqueId;
        MIDIObjectGetIntegerProperty(endpointRef, kMIDIPropertyUniqueID, &uniqueId);
        
        [destinationEndpointIDs addObject:[NSNumber numberWithInt:uniqueId]];
    }

    _destinationEndpointIDs = destinationEndpointIDs;
    
    return YES;
}

- (void)disposeMIDIInPort
{
    MIDIPortDispose(inputPortRef);
    inputPortRef = 0;

    _parsers = nil;
}

- (void)disposeMIDIOutPort
{
    MIDIPortDispose(outputPortRef);
    outputPortRef = 0;
}

- (void)createMIDIClient
{
    OSStatus err;

    NSString *clientName = @"inputClient";
    err = MIDIClientCreate((__bridge CFStringRef)clientName, MyMIDINotifyProc, (__bridge void *)(self), &clientRef);
    if (err != noErr) {
        NSLog(@"MIDIClientCreate err = %d", (int)err);
        return;
    }

    if ([self createMIDIInPort] == NO) {
        return;
    }

    if ([self createMIDIOutPort] == NO) {
        return;
    }

    return;
}

- (void)disposeMIDIClient
{
    MIDIClientDispose(clientRef);
}

- (id)init
{
    self = [super init];
    if (self) {
        mach_timebase_info(&_base);

        [self createMIDIClient];
    }
    
    return self;
}

- (void)dealloc
{
    [self disposeMIDIClient];
}

@end
