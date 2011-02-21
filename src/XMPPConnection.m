/*
 * Copyright (c) 2010, 2011, Jonathan Schleifer <js@webkeks.org>
 * Copyright (c) 2011, Florian Zeitz <florob@babelmonkeys.de>
 *
 * https://webkeks.org/hg/objxmpp/
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

#include <assert.h>

#include <stringprep.h>
#include <idna.h>

#import "XMPPConnection.h"
#import "XMPPSCRAMAuth.h"
#import "XMPPPLAINAuth.h"
#import "XMPPStanza.h"
#import "XMPPJID.h"
#import "XMPPIQ.h"
#import "XMPPExceptions.h"

#define NS_BIND @"urn:ietf:params:xml:ns:xmpp-bind"
#define NS_CLIENT @"jabber:client"
#define NS_SASL @"urn:ietf:params:xml:ns:xmpp-sasl"
#define NS_STREAM @"http://etherx.jabber.org/streams"

@implementation XMPPConnection
@synthesize username, password, server, resource, JID, port, useTLS, delegate;

- init
{
	self = [super init];

	sock = [[OFTCPSocket alloc] init];
	parser = [[OFXMLParser alloc] init];
	elementBuilder = [[OFXMLElementBuilder alloc] init];

	port = 5222;
	useTLS = YES;

	mechanisms = [[OFMutableArray alloc] init];

	parser.delegate = self;
	elementBuilder.delegate = self;

	return self;
}

- (void)dealloc
{
	[sock release];
	[parser release];
	[elementBuilder release];
	[authModule release];

	[super dealloc];
}

- (void)setUsername: (OFString*)username_
{
	OFString *old = username;
	char *node;
	Stringprep_rc rc;

	if ((rc = stringprep_profile([username_ cString], &node,
	    "SASLprep", 0)) != STRINGPREP_OK)
		@throw [XMPPStringPrepFailedException newWithClass: isa
							connection: self
							   profile: @"SASLprep"
							    string: username_];

	@try {
		username = [[OFString alloc] initWithCString: node];
	} @finally {
		free(node);
	}

	[old release];
}

- (void)setResource: (OFString*)resource_
{
	OFString *old = resource;
	char *res;
	Stringprep_rc rc;

	if ((rc = stringprep_profile([resource_ cString], &res,
	    "Resourceprep", 0)) != STRINGPREP_OK)
		@throw [XMPPStringPrepFailedException
		    newWithClass: isa
		      connection: self
			 profile: @"Resourceprep"
			  string: resource_];

	@try {
		resource = [[OFString alloc] initWithCString: res];
	} @finally {
		free(res);
	}

	[old release];
}

- (void)setServer: (OFString*)server_
{
	OFString *old = server;
	char *srv;
	Idna_rc rc;

	if ((rc = idna_to_ascii_8z([server_ cString],
	    &srv, IDNA_USE_STD3_ASCII_RULES)) != IDNA_SUCCESS)
		@throw [XMPPIDNATranslationFailedException
		 newWithClass: isa
		   connection: self
		    operation: @"ToASCII"
		       string: server_];

	@try {
		server = [[OFString alloc] initWithCString: srv];
	} @finally {
		free(srv);
	}

	[old release];
}

- (void)setPassword: (OFString*)password_
{
	OFString *old = password;
	char *pass;
	Stringprep_rc rc;

	if ((rc = stringprep_profile([password_ cString], &pass,
	    "SASLprep", 0)) != STRINGPREP_OK)
		@throw [XMPPStringPrepFailedException newWithClass: isa
							connection: self
							   profile: @"SASLprep"
							    string: password_];

	@try {
		password = [[OFString alloc] initWithCString: pass];
	} @finally {
		free(pass);
	}

	[old release];
}

- (void)_startStream
{
	[sock writeFormat: @"<?xml version='1.0'?>\n"
			   @"<stream:stream to='%@' xmlns='" NS_CLIENT @"' "
			   @"xmlns:stream='" NS_STREAM @"' "
			   @"version='1.0'>", server];
}

- (void)connect
{
	OFAutoreleasePool *pool = [[OFAutoreleasePool alloc] init];

	[sock connectToHost: server
		     onPort: port];
	[self _startStream];

	[pool release];
}

- (void)handleConnection
{
	char buf[512];

	for (;;) {
		size_t len = [sock readNBytes: 512
				   intoBuffer: buf];

		if (len < 1)
			[delegate connectionWasClosed: self];

		[of_stdout writeNBytes: len
			    fromBuffer: buf];
		[parser parseBuffer: buf
			   withSize: len];
	}
}

- (void)sendStanza: (OFXMLElement*)elem
{
	[sock writeString: [elem stringValue]];
}

-    (void)parser: (OFXMLParser*)p
  didStartElement: (OFString*)name
       withPrefix: (OFString*)prefix
	namespace: (OFString*)ns
       attributes: (OFArray*)attrs
{
	if (![name isEqual: @"stream"] || ![prefix isEqual: @"stream"] ||
	    ![ns isEqual: NS_STREAM]) {
		of_log(@"Did not get expected stream start!");
		assert(0);
	}

	for (OFXMLAttribute *attr in attrs) {
		if ([attr.name isEqual: @"from"] &&
		    ![attr.stringValue isEqual: server]) {
			of_log(@"Got invalid from in stream start!");
			assert(0);
		}
	}

	parser.delegate = elementBuilder;
}

- (void)_sendAuth: (OFString*)name
{
	OFXMLElement *authTag;

	authTag = [OFXMLElement elementWithName: @"auth"
				      namespace: NS_SASL];
	[authTag addAttributeWithName: @"mechanism"
			  stringValue: name];
	[authTag addChild: [OFXMLElement elementWithCharacters:
	    [[authModule getClientFirstMessage] stringByBase64Encoding]]];

	[self sendStanza: authTag];
}

- (void)_sendResourceBind
{
	XMPPIQ *iq = [XMPPIQ IQWithType: @"set"
				     ID: @"bind0"];
	OFXMLElement *bind = [OFXMLElement elementWithName: @"bind"
						 namespace: NS_BIND];
	if (resource)
		[bind addChild: [OFXMLElement elementWithName: @"resource"
						  stringValue: resource]];
	[iq addChild: bind];

	[self sendStanza: iq];
}

- (void)_handleResourceBind: (XMPPIQ*)iq
{
	OFXMLElement *bindElem = iq.children.firstObject;

	if ([bindElem.name isEqual: @"bind"] &&
	    [bindElem.namespace isEqual: NS_BIND]) {
		OFXMLElement *jidElem = bindElem.children.firstObject;
		JID = [[XMPPJID alloc] initWithString:
		    [jidElem.children.firstObject stringValue]];
		of_log(@"Bound to JID: %@", [JID fullJID]);
	}
}

- (void)_handleFeatures: (OFXMLElement*)elem
{
	OFArray *mechs = [elem elementsForName: @"mechanisms"
				     namespace: NS_SASL];
	OFXMLElement *bind = [elem elementsForName: @"bind"
					 namespace: NS_BIND].firstObject;

	for (OFXMLElement *mech in [mechs.firstObject children])
		[mechanisms addObject: [mech.children.firstObject stringValue]];

	if ([mechanisms containsObject: @"SCRAM-SHA-1"]) {
		authModule = [[XMPPSCRAMAuth alloc]
		    initWithAuthcid: username
			   password: password
			       hash: [OFSHA1Hash class]];
		[self _sendAuth: @"SCRAM-SHA-1"];
	} else if ([mechanisms containsObject: @"PLAIN"]) {
		authModule = [[XMPPPLAINAuth alloc]
		    initWithAuthcid: username
			   password: password];
		[self _sendAuth: @"PLAIN"];
	}

	if (bind != nil)
		[self _sendResourceBind];
}

- (void)elementBuilder: (OFXMLElementBuilder*)b
       didBuildElement: (OFXMLElement*)elem
{
	elem.defaultNamespace = NS_CLIENT;
	[elem setPrefix: @"stream"
	   forNamespace: NS_STREAM];

	if ([elem.name isEqual: @"features"] &&
	    [elem.namespace isEqual: NS_STREAM]) {
		[self _handleFeatures: elem];
		return;
	}

	if ([elem.namespace isEqual: NS_SASL]) {
		if ([elem.name isEqual: @"challenge"]) {
			OFXMLElement *responseTag;
			OFDataArray *challenge =
			    [OFDataArray dataArrayWithBase64EncodedString:
				[elem.children.firstObject stringValue]];
			OFDataArray *response =
			    [authModule getResponseWithChallenge: challenge];

			responseTag = [OFXMLElement elementWithName: @"response"
							  namespace: NS_SASL];
			[responseTag
			    addChild: [OFXMLElement elementWithCharacters:
				[response stringByBase64Encoding]]];

			[self sendStanza: responseTag];
		} else if ([elem.name isEqual: @"success"]) {
			[authModule parseServerFinalMessage:
			    [OFDataArray dataArrayWithBase64EncodedString:
				[elem.children.firstObject stringValue]]];
			of_log(@"Auth successful");

			/* Stream restart */
			[mechanisms release];
			mechanisms = [[OFMutableArray alloc] init];
			parser.delegate = self;

			[self _startStream];
		} else if ([elem.name isEqual: @"failure"]) {
			of_log(@"Auth failed!");
			// FIXME: Do more parsing/handling
			@throw [XMPPAuthFailedException
			    newWithClass: isa
			      connection: self
				  reason: [elem stringValue]];
		}
	}

	if ([elem.name isEqual: @"iq"] &&
	    [elem.namespace isEqual: NS_CLIENT]) {
		XMPPIQ *iq = [XMPPIQ stanzaWithElement: elem];

		// FIXME: More checking!
		if ([iq.ID isEqual: @"bind0"] && [iq.type isEqual: @"result"])
			[self _handleResourceBind: iq];
	}
}

- (void)elementBuilder: (OFXMLElementBuilder*)b
  didNotExpectCloseTag: (OFString*)name
	    withPrefix: (OFString*)prefix
	     namespace: (OFString*)ns
{
	// TODO
}
@end
