/*
 * Copyright (c) 2011, Florian Zeitz <florob@babelmonkeys.de>
 * Copyright (c) 2011, Jonathan Schleifer <js@webkeks.org>
 *
 * https://webkeks.org/git/?p=objxmpp.git
 *
 * Permission to use, copy, modify, and/or distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice is present in all copies.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
 * LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 * POSSIBILITY OF SUCH DAMAGE.
 */

#ifdef HAVE_CONFIG_H
# include "config.h"
#endif

#include <string.h>
#include <assert.h>
#include <openssl/rand.h>

#import <ObjOpenSSL/SSLSocket.h>

#import "XMPPSCRAMAuth.h"
#import "XMPPExceptions.h"

#define HMAC_IPAD 0x36
#define HMAC_OPAD 0x5c

@implementation XMPPSCRAMAuth
+ SCRAMAuthWithAuthcid: (OFString*)authcid
	      password: (OFString*)password
	    connection: (XMPPConnection*)connection_
		  hash: (Class)hash
	 plusAvailable: (BOOL)plusAvailable_
{
	return [[[self alloc] initWithAuthcid: authcid
				     password: password
				   connection: connection_
					 hash: hash
				plusAvailable: plusAvailable_] autorelease];
}

+ SCRAMAuthWithAuthzid: (OFString*)authzid
	       authcid: (OFString*)authcid
	      password: (OFString*)password
	    connection: (XMPPConnection*)connection_
		  hash: (Class)hash
	 plusAvailable: (BOOL)plusAvailable_
{
	return [[[self alloc] initWithAuthzid: authzid
				      authcid: authcid
				     password: password
				   connection: connection_
					 hash: hash
				plusAvailable: plusAvailable_] autorelease];
}

- initWithAuthcid: (OFString*)authcid_
	 password: (OFString*)password_
       connection: (XMPPConnection*)connection_
	     hash: (Class)hash
    plusAvailable: (BOOL)plusAvailable_
{
	return [self initWithAuthzid: nil
			     authcid: authcid_
			    password: password_
			  connection: connection_
				hash: hash
		       plusAvailable: plusAvailable_];
}

- initWithAuthzid: (OFString*)authzid_
	  authcid: (OFString*)authcid_
	 password: (OFString*)password_
       connection: (XMPPConnection*)connection_
	     hash: (Class)hash
    plusAvailable: (BOOL)plusAvailable_
{
	self = [super initWithAuthzid: authzid_
			      authcid: authcid_
			     password: password_];

	hashType = hash;
	plusAvailable = plusAvailable_;
	connection = [connection_ retain];

	return self;
}

- (void)dealloc
{
	[GS2Header release];
	[clientFirstMessageBare release];
	[serverSignature release];
	[cNonce release];
	[connection release];

	[super dealloc];
}

- (void)setAuthzid: (OFString*)authzid_
{
	OFString *old = authzid;

	if (authzid_) {
		OFMutableString *new = [[authzid_ mutableCopy] autorelease];
		[new replaceOccurrencesOfString: @"="
				     withString: @"=3D"];
		[new replaceOccurrencesOfString: @","
				     withString: @"=2C"];
		authzid = [new retain];
	} else
		authzid = nil;

	[old release];
}

- (void)setAuthcid: (OFString*)authcid_
{
	OFString *old = authcid;

	if (authcid_) {
		OFMutableString *new = [[authcid_ mutableCopy] autorelease];
		[new replaceOccurrencesOfString: @"="
				     withString: @"=3D"];
		[new replaceOccurrencesOfString: @","
				     withString: @"=2C"];
		authcid = [new retain];
	} else
		authcid = nil;

	[old release];
}

- (OFDataArray*)initialMessage
{
	OFDataArray *ret = [OFDataArray dataArray];

	/* New authentication attempt, reset status */
	[cNonce release];
	cNonce = nil;
	[GS2Header release];
	GS2Header = nil;
	[serverSignature release];
	serverSignature = nil;
	authenticated = NO;

	if (authzid)
		GS2Header = [[OFString alloc]
		    initWithFormat: @"%@,a=%@,",
				    (plusAvailable ? @"p=tls-unique" : @"y"),
				    authzid];
	else
		GS2Header = (plusAvailable ? @"p=tls-unique,," : @"y,,");

	cNonce = [[self XMPP_genNonce] retain];

	[clientFirstMessageBare release];
	clientFirstMessageBare = nil;
	clientFirstMessageBare = [[OFString alloc] initWithFormat: @"n=%@,r=%@",
								   authcid,
								   cNonce];

	[ret addItemsFromCArray: [GS2Header UTF8String]
			  count: [GS2Header UTF8StringLength]];

	[ret addItemsFromCArray: [clientFirstMessageBare UTF8String]
			  count: [clientFirstMessageBare UTF8StringLength]];


	return ret;
}

- (OFDataArray*)continueWithData: (OFDataArray*)data
{
	OFAutoreleasePool *pool = [[OFAutoreleasePool alloc] init];
	OFDataArray *ret;

	if (!serverSignature)
		ret = [self XMPP_parseServerFirstMessage: data];
	else
		ret = [self XMPP_parseServerFinalMessage: data];

	[ret retain];
	[pool release];

	return [ret autorelease];
}

- (OFDataArray*)XMPP_parseServerFirstMessage: (OFDataArray*)data
{
	size_t i;
	uint8_t *clientKey, *serverKey, *clientSignature;
	intmax_t iterCount = 0;
	OFHash *hash;
	OFDataArray *ret, *authMessage, *tmpArray, *salt = nil, *saltedPassword;
	OFString *tmpString, *sNonce = nil;
	OFEnumerator *enumerator;
	OFString *comp;
	enum {
		GOT_SNONCE    = 0x01,
		GOT_SALT      = 0x02,
		GOT_ITERCOUNT = 0x04
	} got = 0;

	hash = [[[hashType alloc] init] autorelease];
	ret = [OFDataArray dataArray];
	authMessage = [OFDataArray dataArray];

	OFString *chal = [OFString stringWithUTF8String: [data cArray]
						 length: [data count] *
							 [data itemSize]];

	enumerator =
	    [[chal componentsSeparatedByString: @","] objectEnumerator];
	while ((comp = [enumerator nextObject]) != nil) {
		OFString *entry = [comp substringWithRange:
		    of_range(2, [comp length] - 2)];

		if ([comp hasPrefix: @"r="]) {
			if (![entry hasPrefix: cNonce])
				@throw [XMPPAuthFailedException
				    exceptionWithClass: [self class]
					    connection: nil
						reason: @"Received wrong "
							@"nonce"];

			sNonce = entry;
			got |= GOT_SNONCE;
		} else if ([comp hasPrefix: @"s="]) {
			salt = [OFDataArray
			    dataArrayWithBase64EncodedString: entry];
			got |= GOT_SALT;
		} else if ([comp hasPrefix: @"i="]) {
			iterCount = [entry decimalValue];
			got |= GOT_ITERCOUNT;
		}
	}

	if (got != (GOT_SNONCE | GOT_SALT | GOT_ITERCOUNT))
		@throw [OFInvalidServerReplyException
		    exceptionWithClass: [self class]];

	// Add c=<base64(GS2Header+channelBindingData)>
	tmpArray = [OFDataArray dataArray];
	[tmpArray addItemsFromCArray: [GS2Header UTF8String]
			       count: [GS2Header UTF8StringLength]];
	if (plusAvailable && [connection encrypted]) {
		OFDataArray *channelBinding = [((SSLSocket*)[connection socket])
		    channelBindingDataWithType: @"tls-unique"];
		[tmpArray addItemsFromCArray: [channelBinding cArray]
				       count: [channelBinding count]];
	}
	tmpString = [tmpArray stringByBase64Encoding];
	[ret addItemsFromCArray: "c="
			  count: 2];
	[ret addItemsFromCArray: [tmpString UTF8String]
			  count: [tmpString UTF8StringLength]];

	// Add r=<nonce>
	[ret addItem: ","];
	[ret addItemsFromCArray: "r="
			  count: 2];
	[ret addItemsFromCArray: [sNonce UTF8String]
			  count: [sNonce UTF8StringLength]];

	/*
	 * IETF RFC 5802:
	 * SaltedPassword := Hi(Normalize(password), salt, i)
	 */
	tmpArray = [OFDataArray dataArray];
	[tmpArray addItemsFromCArray: [password UTF8String]
			       count: [password UTF8StringLength]];

	saltedPassword = [self XMPP_hiWithData: tmpArray
					  salt: salt
				iterationCount: iterCount];

	/*
	 * IETF RFC 5802:
	 * AuthMessage := client-first-message-bare + "," +
	 *		  server-first-message + "," +
	 *		  client-final-message-without-proof
	 */
	[authMessage addItemsFromCArray: [clientFirstMessageBare UTF8String]
				  count: [clientFirstMessageBare
					     UTF8StringLength]];
	[authMessage addItem: ","];
	[authMessage addItemsFromCArray: [data cArray]
				  count: [data count] * [data itemSize]];
	[authMessage addItem: ","];
	[authMessage addItemsFromCArray: [ret cArray]
				  count: [ret count]];

	/*
	 * IETF RFC 5802:
	 * ClientKey := HMAC(SaltedPassword, "Client Key")
	 */
	tmpArray = [OFDataArray dataArray];
	[tmpArray addItemsFromCArray: "Client Key"
			       count: 10];
	clientKey = [self XMPP_HMACWithKey: saltedPassword
				      data: tmpArray];

	/*
	 * IETF RFC 5802:
	 * StoredKey := H(ClientKey)
	 */
	[hash updateWithBuffer: (void*) clientKey
			length: [hashType digestSize]];
	tmpArray = [OFDataArray dataArray];
	[tmpArray addItemsFromCArray: [hash digest]
			       count: [hashType digestSize]];

	/*
	 * IETF RFC 5802:
	 * ClientSignature := HMAC(StoredKey, AuthMessage)
	 */
	clientSignature = [self XMPP_HMACWithKey: tmpArray
					    data: authMessage];

	/*
	 * IETF RFC 5802:
	 * ServerKey := HMAC(SaltedPassword, "Server Key")
	 */
	tmpArray = [OFDataArray dataArray];
	[tmpArray addItemsFromCArray: "Server Key"
			       count: 10];
	serverKey = [self XMPP_HMACWithKey: saltedPassword
				      data: tmpArray];

	/*
	 * IETF RFC 5802:
	 * ServerSignature := HMAC(ServerKey, AuthMessage)
	 */
	tmpArray = [OFDataArray dataArray];
	[tmpArray addItemsFromCArray: serverKey
			       count: [hashType digestSize]];
	serverSignature = [[OFDataArray alloc] init];
	[serverSignature addItemsFromCArray: [self
						 XMPP_HMACWithKey: tmpArray
							     data: authMessage]
				      count: [hashType digestSize]];

	/*
	 * IETF RFC 5802:
	 * ClientProof := ClientKey XOR ClientSignature
	 */
	tmpArray = [OFDataArray dataArray];
	for (i = 0; i < [hashType digestSize]; i++) {
		uint8_t c = clientKey[i] ^ clientSignature[i];
		[tmpArray addItem: &c];
	}

	// Add p=<base64(ClientProof)>
	[ret addItem: ","];
	[ret addItemsFromCArray: "p="
			  count: 2];
	tmpString = [tmpArray stringByBase64Encoding];
	[ret addItemsFromCArray: [tmpString UTF8String]
			  count: [tmpString UTF8StringLength]];

	return ret;
}

- (OFDataArray*)XMPP_parseServerFinalMessage: (OFDataArray*)data
{
	OFString *mess, *value;

	/*
	 * server-final-message already received,
	 * we were just waiting for the last word from the server
	 */
	if (authenticated)
		return nil;

	mess = [OFString stringWithUTF8String: [data cArray]
				       length: [data count] *
					       [data itemSize]];
	value = [mess substringWithRange: of_range(2, [mess length] - 2)];

	if ([mess hasPrefix: @"v="]) {
		if (![value isEqual: [serverSignature stringByBase64Encoding]])
			@throw [XMPPAuthFailedException
			    exceptionWithClass: [self class]
				    connection: nil
					reason: @"Received wrong "
						@"ServerSignature"];
		authenticated = YES;
	} else
		@throw [XMPPAuthFailedException exceptionWithClass: [self class]
							connection: nil
							    reason: value];

	return nil;
}

- (OFString*)XMPP_genNonce
{
	uint8_t buf[64];
	size_t i;

	assert(RAND_pseudo_bytes(buf, 64) >= 0);

	for (i = 0; i < 64; i++) {
		// Restrict salt to printable range, but do not include '~'...
		buf[i] = (buf[i] % ('~' - '!')) + '!';

		// ...so we can use it to replace ','
		if (buf[i] == ',')
			buf[i] = '~';
	}

	return [OFString stringWithCString: (char*)buf
				  encoding: OF_STRING_ENCODING_ASCII
				    length: 64];
}

- (uint8_t*)XMPP_HMACWithKey: (OFDataArray*)key
			data: (OFDataArray*)data
{
	OFAutoreleasePool *pool = [[OFAutoreleasePool alloc] init];
	OFDataArray *k = [OFDataArray dataArray];
	size_t i, kSize, blockSize = [hashType blockSize];
	uint8_t *kI = NULL, *kO = NULL;
	OFHash *hashI, *hashO;

	if ([key itemSize] * [key count] > blockSize) {
		hashI = [[[hashType alloc] init] autorelease];
		[hashI updateWithBuffer: [key cArray]
				length: [key itemSize] * [key count]];
		[k addItemsFromCArray: [hashI digest]
				count: [hashType digestSize]];
	} else
		[k addItemsFromCArray: [key cArray]
				count: [key itemSize] * [key count]];

	@try {
		kI = [self allocMemoryWithSize: blockSize];
		kO = [self allocMemoryWithSize: blockSize];

		kSize = [k count];
		memcpy(kI, [k cArray], kSize);
		memset(kI + kSize, 0, blockSize - kSize);
		memcpy(kO, kI, blockSize);

		for (i = 0; i < blockSize; i++) {
			kI[i] ^= HMAC_IPAD;
			kO[i] ^= HMAC_OPAD;
		}

		hashI = [[[hashType alloc] init] autorelease];
		[hashI updateWithBuffer: (char*)kI
				 length: blockSize];
		[hashI updateWithBuffer: [data cArray]
				 length: [data itemSize] * [data count]];

		hashO = [[[hashType alloc] init] autorelease];
		[hashO updateWithBuffer: (char*)kO
				 length: blockSize];
		[hashO updateWithBuffer: (char*)[hashI digest]
				 length: [hashType digestSize]];
	} @finally {
		[self freeMemory: kI];
		[self freeMemory: kO];
	}

	[hashO retain];
	[pool release];

	return [[hashO autorelease] digest];
}

- (OFDataArray*)XMPP_hiWithData: (OFDataArray *)str
			   salt: (OFDataArray *)salt_
		 iterationCount: (intmax_t)i
{
	OFAutoreleasePool *pool = [[OFAutoreleasePool alloc] init];
	size_t digestSize = [hashType digestSize];
	uint8_t *result = NULL, *u, *uOld;
	intmax_t j, k;
	OFDataArray *salty, *tmp, *ret;

	result = [self allocMemoryWithSize: digestSize];

	@try {
		memset(result, 0, digestSize);

		salty = [[salt_ copy] autorelease];
		[salty addItemsFromCArray: "\0\0\0\1"
				    count: 4];

		uOld = [self XMPP_HMACWithKey: str
					 data: salty];

		for (j = 0; j < digestSize; j++)
			result[j] ^= uOld[j];

		for (j = 0; j < i - 1; j++) {
			tmp = [OFDataArray dataArray];
			[tmp addItemsFromCArray: uOld
					  count: digestSize];

			u = [self XMPP_HMACWithKey: str
					      data: tmp];

			for (k = 0; k < digestSize; k++)
				result[k] ^= u[k];

			uOld = u;

			[pool releaseObjects];
		}

		ret = [OFDataArray dataArray];
		[ret addItemsFromCArray: result
				  count: digestSize];
	} @finally {
		[self freeMemory: result];
	}

	[ret retain];
	[pool release];

	return [ret autorelease];
}
@end
