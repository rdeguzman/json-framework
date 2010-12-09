/*
 Copyright (c) 2010, Stig Brautaset.
 All rights reserved.
 
 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are
 met:
 
   Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.
  
   Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.
 
   Neither the name of the the author nor the names of its contributors
   may be used to endorse or promote products derived from this software
   without specific prior written permission.
 
 THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS
 IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
 TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A
 PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
 HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
 SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
 LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
 DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
 THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "SBJsonStreamParser.h"
#import "SBJsonTokeniser.h"
#import "SBJsonStreamParserState.h"


@implementation SBJsonStreamParser

@synthesize multi;
@synthesize error;
@synthesize delegate;
@synthesize maxDepth;
@synthesize states;
@synthesize depth;

#pragma mark Housekeeping

- (id)init {
	self = [super init];
	if (self) {
		tokeniser = [SBJsonTokeniser new];
		maxDepth = 512;
		states = calloc(maxDepth, sizeof(SBJsonStreamParserState*));
		NSAssert(states, @"States not initialised");
		states[0] = [SBJsonStreamParserStateStart sharedInstance];
	}
	return self;
}

- (void)dealloc {
	[tokeniser release];
	[error release];
	[super dealloc];
}

#pragma mark Methods

- (NSString*)tokenName:(sbjson_token_t)token {
	switch (token) {
		case sbjson_token_array_start:
			return @"start of array";
			break;
			
		case sbjson_token_array_end:
			return @"end of array";
			break;

		case sbjson_token_double:
		case sbjson_token_integer:
			return @"number";
			break;
			
		case sbjson_token_string:
		case sbjson_token_string_encoded:
			return @"string";
			break;
			
		case sbjson_token_true:
		case sbjson_token_false:
			return @"boolean";
			break;
			
		case sbjson_token_null:
			return @"null";
			break;
			
		case sbjson_token_key_value_separator:
			return @"key-value separator";
			break;
			
		case sbjson_token_separator:
			return @"value separator";
			break;
			
		case sbjson_token_object_start:
			return @"start of object";
			break;
			
		case sbjson_token_object_end:
			return @"end of object";
			break;
			
		case sbjson_token_eof:
		case sbjson_token_error:
			break;
	}
	NSAssert(NO, @"Should not get here");
	return @"<aaiiie!>";
}


- (SBJsonStreamParserStatus)parse:(NSData *)data {
	[tokeniser appendData:data];
	
	const char *buf;
	NSUInteger len;
	
	for (;;) {		
		if ([states[depth] parserShouldStop:self])
			return [states[depth] parserShouldReturn:self];
		
		sbjson_token_t tok = [tokeniser next];
		
		switch (tok) {
			case sbjson_token_eof:
				return SBJsonStreamParserWaitingForData;
				break;

			case sbjson_token_error:
				states[depth] = [SBJsonStreamParserStateError sharedInstance];
				self.error = tokeniser.error;
				return SBJsonStreamParserError;
				break;

			default:
				
				if (![states[depth] parser:self shouldAcceptToken:tok]) {
					NSString *tokenName = [self tokenName:tok];
					NSString *stateName = [states[depth] name];
					self.error = [NSString stringWithFormat:@"Token '%@' not expected %@", tokenName, stateName];
					states[depth] = [SBJsonStreamParserStateError sharedInstance];
					return SBJsonStreamParserError;
				}
				
				switch (tok) {
					case sbjson_token_object_start:
						if (depth >= maxDepth) {
							self.error = [NSString stringWithFormat:@"Parser exceeded max depth of %lu", maxDepth];
							states[depth] = [SBJsonStreamParserStateError sharedInstance];

						} else {
							[delegate parserStartedObject:self];
							states[++depth] = [SBJsonStreamParserStateObjectStart sharedInstance];
						}
						break;
						
					case sbjson_token_object_end:
						[states[--depth] parser:self shouldTransitionTo:tok];
						[delegate parserEndedObject:self];
						break;
						
					case sbjson_token_array_start:
						if (depth >= maxDepth) {
							self.error = [NSString stringWithFormat:@"Parser exceeded max depth of %lu", maxDepth];
							states[depth] = [SBJsonStreamParserStateError sharedInstance];
						} else {
							[delegate parserStartedArray:self];
							states[++depth] = [SBJsonStreamParserStateArrayStart sharedInstance];
						}						
						break;
						
					case sbjson_token_array_end:
						[states[--depth] parser:self shouldTransitionTo:tok];
						[delegate parserEndedArray:self];
						break;
						
					case sbjson_token_separator:
					case sbjson_token_key_value_separator:
						[states[depth] parser:self shouldTransitionTo:tok];
						break;
						
					case sbjson_token_true:
						[delegate parser:self foundBoolean:YES];
						[states[depth] parser:self shouldTransitionTo:tok];
						break;

					case sbjson_token_false:
						[delegate parser:self foundBoolean:NO];
						[states[depth] parser:self shouldTransitionTo:tok];
						break;

					case sbjson_token_null:
						[delegate parserFoundNull:self];
						[states[depth] parser:self shouldTransitionTo:tok];
						break;
						
					case sbjson_token_integer:
					case sbjson_token_double:
						if ([tokeniser getToken:&buf length:&len]) {
							NSData *data = [NSData dataWithBytes:buf length:len];
							NSString *string = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
							NSDecimalNumber *number = [[NSDecimalNumber alloc] initWithString:string];
							[delegate parser:self foundNumber:number];
							[number release];
							[string release];

						}
						[states[depth] parser:self shouldTransitionTo:tok];
						break;

					case sbjson_token_string:
						NSAssert([tokeniser getToken:&buf length:&len], @"failed to get token");
						NSString *string = [[NSString alloc] initWithBytes:buf+1 length:len-2 encoding:NSUTF8StringEncoding];
						NSParameterAssert(string);
						if ([states[depth] needKey])
							[delegate parser:self foundObjectKey:string];
						else
							[delegate parser:self foundString:string];
						[string release];
						[states[depth] parser:self shouldTransitionTo:tok];
						break;
						
					case sbjson_token_string_encoded:
						NSAssert([tokeniser getToken:&buf length:&len], @"failed to get token");
						NSString *decoded = [tokeniser getDecodedStringToken];
						NSParameterAssert(decoded);
						if ([states[depth] needKey])
							[delegate parser:self foundObjectKey:decoded];
						else
							[delegate parser:self foundString:decoded];
						[states[depth] parser:self shouldTransitionTo:tok];
						break;
						
					default:
						break;
				}
				break;
		}
	}
	return SBJsonStreamParserComplete;
}


@end
