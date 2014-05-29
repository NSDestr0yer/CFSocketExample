//
//  AppDelegate.m
//  Socket
//
//  Created by Collin B. Stuart on 2014-05-15.
//  Copyright (c) 2014 CollinBStuart. All rights reserved.
//

#import "AppDelegate.h"
#include <arpa/inet.h> //for PF_INET, SOCK_STREAM, IPPROTO_TCP etc
#include <netdb.h> //for gethostbyname

CFRunLoopSourceRef gSocketSource = NULL;

CF_ENUM(CFIndex, SMTPStep)
{
    kSMTPStepConnect,
    kSMTPStepHelo,
    kSMTPStepClose
};

CFIndex currentStep = kSMTPStepConnect;

@implementation AppDelegate



void CloseSocket(CFSocketRef socket)
{
    printf("Closing socket\n");
    
    //cleanup - invalidate below will also remove from runloop...
    if (gSocketSource)
    {
        CFRunLoopRef currentRunLoop = CFRunLoopGetCurrent();
        if (CFRunLoopContainsSource(currentRunLoop, gSocketSource, kCFRunLoopDefaultMode))
        {
            CFRunLoopRemoveSource(currentRunLoop, gSocketSource, kCFRunLoopDefaultMode);
        }
        CFRelease(gSocketSource);
    }
    
    if (socket) //close socket
    {
        if (CFSocketIsValid(socket))
        {
            CFSocketInvalidate(socket);
        }
        CFRelease(socket);
    }
}

void SocketCallBack(CFSocketRef socket, CFSocketCallBackType type, CFDataRef address, const void *data, void *info)
{
    CFArrayRef stepArray = (CFArrayRef)info;
    
    CFDictionaryRef currentStepDictionary = NULL;
    if (currentStep < CFArrayGetCount(stepArray))
    {
        currentStepDictionary = (CFDictionaryRef)CFArrayGetValueAtIndex(stepArray, currentStep);
    }
    if (!currentStepDictionary)
    {
        return;
    }
    
    if (type == kCFSocketConnectCallBack)
    {
        printf("connected\n\n");
    }
    else if (type == kCFSocketDataCallBack)
    {
        printf("buffer has read data\n");
        UInt8 *buffer = (UInt8 *)CFDataGetBytePtr((CFDataRef)data);
        CFIndex length = CFDataGetLength((CFDataRef)data);
        CFStringRef returnedString = CFStringCreateWithBytes(kCFAllocatorDefault, buffer, length, kCFStringEncodingUTF8, TRUE);

        //if we have correct response code
        if ( CFStringFind(returnedString, (CFStringRef)CFDictionaryGetValue(currentStepDictionary, CFSTR("keyResult")), 0).location != kCFNotFound )
        {
            
            
            //move on to next step
            currentStep++;

            //turn off read data and enable write
            CFSocketDisableCallBacks(socket, kCFSocketDataCallBack);
            CFSocketEnableCallBacks(socket, kCFSocketWriteCallBack);

        }
        
        CFShow(returnedString);
        CFRelease(returnedString);
        
        //if finished, close the socket
        CFNumberRef theStepNumber = (CFNumberRef)CFDictionaryGetValue(currentStepDictionary, CFSTR("keyStep"));
        CFIndex step;
        CFNumberGetValue(theStepNumber, kCFNumberCFIndexType, &step);
        if (step == kSMTPStepClose)
        {
            CloseSocket(socket);
        }
        
    }
    else if (type == kCFSocketWriteCallBack)
    {
        printf("Buffer Writable\n");
        CFNumberRef theStepNumber = (CFNumberRef)CFDictionaryGetValue(currentStepDictionary, CFSTR("keyStep"));
        CFIndex step;
        CFNumberGetValue(theStepNumber, kCFNumberCFIndexType, &step);
        if (step == currentStep)
        {
            
            CFStringRef string = (CFStringRef)CFDictionaryGetValue(currentStepDictionary, CFSTR("keyCommand"));
            if (string && ( CFGetTypeID(string) != CFNullGetTypeID() ))
            {
                //turn off write, enable read data
                CFSocketDisableCallBacks(socket, kCFSocketWriteCallBack);
                CFSocketEnableCallBacks(socket, kCFSocketDataCallBack);
                
                const char *sendChar = CFStringGetCStringPtr(string, kCFStringEncodingUTF8);
            
                printf("Writing %s\n", sendChar);
                CFDataRef sendData = CFDataCreate(kCFAllocatorDefault, (const UInt8 *)sendChar, strlen(sendChar));
                CFSocketSendData(socket, address, sendData, 30);
                CFRelease(sendData);
                
            } //end if string

        } //end if (step == currentStep)
        
    } //end if (type == kCFSocketWriteCallBack)
}

const void *RetainSocketStreamHandle(const void *info)
{
    CFRetain(info);
    return info;
}

void ReleaseSocketStreamHandle(const void *info)
{
    if (info)
    {
        CFRelease(info);
    }
}

void ResolutionCallBackFunction(CFHostRef host, CFHostInfoType typeInfo, const CFStreamError *error, void *info)
{
    Boolean hostsResolved;
    CFArrayRef addressesArray = CFHostGetAddressing(host, &hostsResolved);
    
    CFSocketContext context = {0, (void *)info, RetainSocketStreamHandle, ReleaseSocketStreamHandle, NULL};
    CFSocketRef theSocket = CFSocketCreate(kCFAllocatorDefault, PF_INET, SOCK_STREAM, IPPROTO_TCP, kCFSocketConnectCallBack | kCFSocketDataCallBack | kCFSocketWriteCallBack, (CFSocketCallBack)SocketCallBack, &context);
    CFSocketSetSocketFlags(theSocket, kCFSocketCloseOnInvalidate);

    
    if (addressesArray && CFArrayGetCount(addressesArray))
    {
        CFDataRef socketData = (CFDataRef)CFArrayGetValueAtIndex(addressesArray, 0);
        
        //Here our connection only accepts port 25 - so we must explicitly change this
        //first, we copy the data so we can change it
        CFDataRef socketDataCopy = CFDataCreateCopy(kCFAllocatorDefault, socketData);
        struct sockaddr_in *addressStruct = (struct sockaddr_in *)CFDataGetBytePtr(socketDataCopy);
        addressStruct->sin_port = htons(25);
        
        //connect
        CFSocketError socketError = CFSocketConnectToAddress(theSocket, socketDataCopy, 30);
        CFRelease(socketDataCopy);
        if (socketError != kCFSocketSuccess)
        {
            printf("Error sending login fail to socket connection\n");
        }
    }
    if (host)
    {
        CFRelease(host);
    }
    
    gSocketSource = CFSocketCreateRunLoopSource(kCFAllocatorDefault, theSocket, 0);
    CFRunLoopAddSource(CFRunLoopGetCurrent(), gSocketSource, kCFRunLoopDefaultMode);
}

void ConnectSocketAndSendCommandArray(CFArrayRef array)
{
    
    //POSIX way...
//    struct sockaddr_in socketAddress;
//    memset(&socketAddress, 0, sizeof(socketAddress));
//    socketAddress.sin_len = sizeof(socketAddress);
//    socketAddress.sin_family = AF_INET;
//    socketAddress.sin_port = htons(25);
//    const char *c = "mail.port25.com";
//    struct hostent *host_entry = gethostbyname(c); //blocks, need seperate thread? does it wake up radio?
//    if (host_entry)
//    {
//        char *ip_addr = inet_ntoa(*((struct in_addr *)host_entry->h_addr_list[0]));
//        socketAddress.sin_addr.s_addr = inet_addr(ip_addr);
//
//        CFDataRef socketData = CFDataCreate(kCFAllocatorDefault, (const UInt8 *)&socketAddress, sizeof(socketAddress));
//        CFSocketConnectToAddress(theSocket, socketData, 30);
//        CFRelease(socketData);
//    }
    
    
    //CFNetwork way...
    CFHostRef host = CFHostCreateWithName(kCFAllocatorDefault, CFSTR("mail.port25.com"));
    CFStreamError streamError;
    CFHostClientContext hostContext = {0, (void *)array, RetainSocketStreamHandle, ReleaseSocketStreamHandle, NULL};
    CFHostSetClient(host, ResolutionCallBackFunction, &hostContext);
    CFHostScheduleWithRunLoop(host, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    Boolean started = CFHostStartInfoResolution(host, kCFHostAddresses, &streamError);
    if (!started)
    {
        printf("Could not start info resolution\n");
    }
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    //SMTP codes
    //220 service is running
    //250 action OK
    //221 closing connection
    CFDictionaryRef theDict[3];
    CFStringRef keys[3] = {CFSTR("keyStep"), CFSTR("keyCommand"), CFSTR("keyResult")};
    
    //first step
    CFIndex stepIndex = 0;
    CFNumberRef number = CFNumberCreate(kCFAllocatorDefault, kCFNumberCFIndexType, &stepIndex);
    const void *firstValues[3] = {number, kCFNull, CFSTR("220")};
    theDict[0] = CFDictionaryCreate(kCFAllocatorDefault, (const void **)keys, firstValues, 3, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFRelease(number);
    
    //second step
    stepIndex = 1;
    number = CFNumberCreate(kCFAllocatorDefault, kCFNumberCFIndexType, &stepIndex);
    const void *secondValues[3] = {number, CFSTR("HELO iOSClient.test.com\n"), CFSTR("250")};
    theDict[1] = CFDictionaryCreate(kCFAllocatorDefault, (const void **)keys, secondValues, 3, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFRelease(number);
    
    //third step
    stepIndex = 2;
    number = CFNumberCreate(kCFAllocatorDefault, kCFNumberCFIndexType, &stepIndex);
    const void *thirdValues[3] = {number, CFSTR("QUIT\n"), CFSTR("221")};
    theDict[2] = CFDictionaryCreate(kCFAllocatorDefault, (const void **)keys, thirdValues, 3, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFRelease(number);
    
    //add to array
    CFArrayRef stepArray = CFArrayCreate(kCFAllocatorDefault, (const void **)theDict, 3, &kCFTypeArrayCallBacks);
    CFRelease(theDict[0]);
    CFRelease(theDict[1]);
    CFRelease(theDict[2]);
    ConnectSocketAndSendCommandArray(stepArray);
    CFRelease(stepArray);
    
    return YES;
}
							
- (void)applicationWillResignActive:(UIApplication *)application
{
    // Sent when the application is about to move from active to inactive state. This can occur for certain types of temporary interruptions (such as an incoming phone call or SMS message) or when the user quits the application and it begins the transition to the background state.
    // Use this method to pause ongoing tasks, disable timers, and throttle down OpenGL ES frame rates. Games should use this method to pause the game.
}

- (void)applicationDidEnterBackground:(UIApplication *)application
{
    // Use this method to release shared resources, save user data, invalidate timers, and store enough application state information to restore your application to its current state in case it is terminated later. 
    // If your application supports background execution, this method is called instead of applicationWillTerminate: when the user quits.
}

- (void)applicationWillEnterForeground:(UIApplication *)application
{
    // Called as part of the transition from the background to the inactive state; here you can undo many of the changes made on entering the background.
}

- (void)applicationDidBecomeActive:(UIApplication *)application
{
    // Restart any tasks that were paused (or not yet started) while the application was inactive. If the application was previously in the background, optionally refresh the user interface.
}

- (void)applicationWillTerminate:(UIApplication *)application
{
    // Called when the application is about to terminate. Save data if appropriate. See also applicationDidEnterBackground:.
}

@end
