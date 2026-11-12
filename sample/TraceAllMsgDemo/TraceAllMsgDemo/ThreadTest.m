//
//  ThreadTest.m
//  TraceAllMsgDemo
//
//  Created by everettjf on 2017/9/19.
//  Copyright © 2017年 AtomSprout. All rights reserved.
//

#import "ThreadTest.h"

@implementation ThreadTest

- (void)go{
    usleep(20);
    [self goOne];
}

- (void)goOne{
    [self goTwo];
}

- (void)goTwo{
    for(int i=0;i<10;i++){
        [self goLoop];
    }
}

- (void)goLoop{
    usleep(20);
}

@end
