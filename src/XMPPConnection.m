/*
 * Copyright (c) 2010, 2011, 2012, 2013, 2015, 2016, 2017, 2018
 *   Jonathan Schleifer <js@heap.zone>
 * Copyright (c) 2011, 2012, Florian Zeitz <florob@babelmonkeys.de>
 *
 * https://heap.zone/objxmpp/
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

#define XMPP_CONNECTION_M

#include <assert.h>

#include <stringprep.h>
#include <idna.h>

#import <ObjOpenSSL/SSLSocket.h>
#import <ObjOpenSSL/SSLInvalidCertificateException.h>
#import <ObjOpenSSL/X509Certificate.h>

#import <ObjFW/OFInvalidArgumentException.h>

#import "XMPPConnection.h"
#import "XMPPCallback.h"
#import "XMPPEXTERNALAuth.h"
#import "XMPPSCRAMAuth.h"
#import "XMPPPLAINAuth.h"
#import "XMPPStanza.h"
#import "XMPPJID.h"
#import "XMPPIQ.h"
#import "XMPPMessage.h"
#import "XMPPPresence.h"
#import "XMPPMulticastDelegate.h"
#import "XMPPExceptions.h"
#import "XMPPXMLElementBuilder.h"
#import "namespaces.h"

#import <ObjFW/macros.h>

#define BUFFER_LENGTH 512

OF_ASSUME_NONNULL_BEGIN

@interface XMPPConnection ()
- (void)XMPP_startStream;
- (void)XMPP_handleStream: (OFXMLElement *)element;
- (void)XMPP_handleTLS: (OFXMLElement *)element;
- (void)XMPP_handleSASL: (OFXMLElement *)element;
- (void)XMPP_handleStanza: (OFXMLElement *)element;
- (void)XMPP_sendAuth: (OFString *)authName;
- (void)XMPP_sendResourceBind;
- (void)XMPP_sendStreamError: (OFString *)condition
			text: (nullable OFString *)text;
- (void)XMPP_handleIQ: (XMPPIQ *)IQ;
- (void)XMPP_handleMessage: (XMPPMessage *)message;
- (void)XMPP_handlePresence: (XMPPPresence *)presence;
- (void)XMPP_handleFeatures: (OFXMLElement *)element;
- (void)XMPP_handleResourceBindForConnection: (XMPPConnection *)connection
					  IQ: (XMPPIQ *)IQ;
- (void)XMPP_sendSession;
- (void)XMPP_handleSessionForConnection: (XMPPConnection *)connection
				     IQ: (XMPPIQ *)IQ;
- (OFString *)XMPP_IDNAToASCII: (OFString *)domain;
- (XMPPMulticastDelegate *)XMPP_delegates;
@end

OF_ASSUME_NONNULL_END

@implementation XMPPConnection
@synthesize username = _username, resource = _resource, server = _server;
@synthesize domain = _domain, password = _password, language = _language;
@synthesize privateKeyFile = _privateKeyFile;
@synthesize certificateFile = _certificateFile, socket = _socket;
@synthesize encryptionRequired = _encryptionRequired, encrypted = _encrypted;
@synthesize supportsRosterVersioning = _supportsRosterVersioning;
@synthesize supportsStreamManagement = _supportsStreamManagement;

+ (instancetype)connection
{
	return [[[self alloc] init] autorelease];
}

- init
{
	self = [super init];

	@try {
		_port = 5222;
		_delegates = [[XMPPMulticastDelegate alloc] init];
		_callbacks = [[OFMutableDictionary alloc] init];
	} @catch (id e) {
		[self release];
		@throw e;
	}

	return self;
}

- (void)dealloc
{
	[_socket release];
	[_parser release];
	[_elementBuilder release];
	[_username release];
	[_password release];
	[_privateKeyFile release];
	[_certificateFile release];
	[_server release];
	[_domain release];
	[_resource release];
	[_JID release];
	[_delegates release];
	[_callbacks release];
	[_authModule release];

	[super dealloc];
}

- (void)setUsername: (OFString *)username
{
	OFString *old = _username;

	if (username != nil) {
		char *node;
		Stringprep_rc rc;

		if ((rc = stringprep_profile([username UTF8String], &node,
		    "SASLprep", 0)) != STRINGPREP_OK)
			@throw [XMPPStringPrepFailedException
			    exceptionWithConnection: self
					    profile: @"SASLprep"
					     string: username];

		@try {
			_username = [[OFString alloc] initWithUTF8String: node];
		} @finally {
			free(node);
		}
	} else
		_username = nil;

	[old release];
}

- (void)setResource: (OFString *)resource
{
	OFString *old = _resource;

	if (resource != nil) {
		char *res;
		Stringprep_rc rc;

		if ((rc = stringprep_profile([resource UTF8String], &res,
		    "Resourceprep", 0)) != STRINGPREP_OK)
			@throw [XMPPStringPrepFailedException
			    exceptionWithConnection: self
					    profile: @"Resourceprep"
					     string: resource];

		@try {
			_resource = [[OFString alloc] initWithUTF8String: res];
		} @finally {
			free(res);
		}
	} else
		_resource = nil;

	[old release];
}

- (void)setServer: (OFString *)server
{
	OFString *old = _server;

	if (server != nil)
		_server = [self XMPP_IDNAToASCII: server];
	else
		_server = nil;

	[old release];
}

- (void)setDomain: (OFString *)domain
{
	OFString *oldDomain = _domain;
	OFString *oldDomainToASCII = _domainToASCII;

	if (domain != nil) {
		char *srv;
		Stringprep_rc rc;

		if ((rc = stringprep_profile([domain UTF8String], &srv,
		    "Nameprep", 0)) != STRINGPREP_OK)
			@throw [XMPPStringPrepFailedException
			    exceptionWithConnection: self
					    profile: @"Nameprep"
					     string: domain];

		@try {
			_domain = [[OFString alloc] initWithUTF8String: srv];
		} @finally {
			free(srv);
		}

		_domainToASCII = [self XMPP_IDNAToASCII: _domain];
	} else {
		_domain = nil;
		_domainToASCII = nil;
	}

	[oldDomain release];
	[oldDomainToASCII release];
}

- (void)setPassword: (OFString *)password
{
	OFString *old = _password;

	if (password != nil) {
		char *pass;
		Stringprep_rc rc;

		if ((rc = stringprep_profile([password UTF8String], &pass,
		    "SASLprep", 0)) != STRINGPREP_OK)
			@throw [XMPPStringPrepFailedException
			    exceptionWithConnection: self
					    profile: @"SASLprep"
					     string: password];

		@try {
			_password = [[OFString alloc] initWithUTF8String: pass];
		} @finally {
			free(pass);
		}
	} else
		_password = nil;

	[old release];
}

- (void)XMPP_socketDidConnect: (OFTCPSocket *)socket
		      context: (OFArray *)nextSRVRecords
		    exception: (id)exception
{
	char *buffer;

	if (exception != nil) {
		if (nextSRVRecords != nil) {
			[self XMPP_tryNextSRVRecord: nextSRVRecords];
			return;
		}

		[_delegates
		    broadcastSelector: @selector(connection:didThrowException:)
			   withObject: self
			   withObject: exception];
		return;
	}

	[self XMPP_startStream];

	buffer = [self allocMemoryWithSize: BUFFER_LENGTH];
	[_socket asyncReadIntoBuffer: buffer
			      length: BUFFER_LENGTH
			      target: self
			    selector: @selector(XMPP_stream:didReadIntoBuffer:
					  length:exception:)
			     context: nil];
}

- (void)XMPP_tryNextSRVRecord: (OFArray *)SRVRecords
{
	OFSRVDNSResourceRecord *record = [SRVRecords objectAtIndex: 0];

	SRVRecords = [SRVRecords objectsInRange:
	    of_range(1, [SRVRecords count] - 1)];
	if ([SRVRecords count] == 0)
		SRVRecords = nil;

	[_socket asyncConnectToHost: [record target]
			       port: [record port]
			     target: self
			   selector: @selector(XMPP_socketDidConnect:
					 context:exception:)
			    context: SRVRecords];
}

-  (void)XMPP_resolver: (OFDNSResolver *)resolver
  didResolveDomainName: (OFString *)domainName
	 answerRecords: (OFDictionary *)answerRecords
      authorityRecords: (OFDictionary *)authorityRecords
     additionalRecords: (OFDictionary *)additionalRecords
	       context: (OFString *)domainToASCII
	     exception: (id)exception
{
	OFMutableArray *records = [OFMutableArray array];

	if (exception != nil) {
		[_delegates
		    broadcastSelector: @selector(connection:didThrowException:)
			   withObject: self
			   withObject: exception];
		return;
	}

	for (OF_KINDOF(OFDNSResourceRecord *) record in
	    [answerRecords objectForKey: domainName])
		if ([record isKindOfClass: [OFSRVDNSResourceRecord class]])
		       [records addObject: record];

	/* TODO: Sort records */
	[records makeImmutable];

	if ([records count] == 0) {
		/* Fall back to A / AAA record. */
		[_socket asyncConnectToHost: domainToASCII
				       port: _port
				     target: self
				   selector: @selector(XMPP_socketDidConnect:
						 context:exception:)
				    context: nil];
		return;
	}

	[self XMPP_tryNextSRVRecord: records];
}

- (void)asyncConnect
{
	void *pool = objc_autoreleasePoolPush();

	if (_socket != nil)
		@throw [OFAlreadyConnectedException exception];

	_socket = [[OFTCPSocket alloc] init];

	if (_server != nil)
		[_socket asyncConnectToHost: _server
				       port: _port
				     target: self
				   selector: @selector(XMPP_socketDidConnect:
						 context:exception:)
				    context: nil];
	else
		[[OFThread DNSResolver]
		    asyncResolveHost: _domainToASCII
			      target: self
			    selector: @selector(XMPP_resolver:
					  didResolveDomainName:answerRecords:
					  authorityRecords:additionalRecords:
					  context:exception:)
			     context: _domainToASCII];

	objc_autoreleasePoolPop(pool);
}

-  (bool)XMPP_parseBuffer: (const void *)buffer
		   length: (size_t)length
{
	if ([_socket isAtEndOfStream]) {
		[_delegates broadcastSelector: @selector(connectionWasClosed:)
				   withObject: self];
		return false;
	}

	@try {
		[_parser parseBuffer: buffer
			     length: length];
	} @catch (OFMalformedXMLException *e) {
		[self XMPP_sendStreamError: @"bad-format"
				      text: nil];
		[self close];
		return false;
	}

	return true;
}

- (void)parseBuffer: (const void *)buffer
	     length: (size_t)length
{
	[self XMPP_parseBuffer: buffer
			length: length];

	[_oldParser release];
	[_oldElementBuilder release];

	_oldParser = nil;
	_oldElementBuilder = nil;
}

- (bool)XMPP_stream: (OFStream *)stream
  didReadIntoBuffer: (char *)buffer
	     length: (size_t)length
	  exception: (OFException *)exception
{
	if (exception != nil) {
		[_delegates broadcastSelector: @selector(connection:
						   didThrowException:)
				   withObject: self
				   withObject: exception];
		[self close];
		return false;
	}

	@try {
		if (![self XMPP_parseBuffer: buffer
				     length: length])
			return false;
	} @catch (id e) {
		[_delegates broadcastSelector: @selector(connection:
						   didThrowException:)
				   withObject: self
				   withObject: e];
		[self close];
		return false;
	}

	if (_oldParser != nil || _oldElementBuilder != nil) {
		[_oldParser release];
		[_oldElementBuilder release];

		_oldParser = nil;
		_oldElementBuilder = nil;

		[_socket asyncReadIntoBuffer: buffer
				      length: BUFFER_LENGTH
				      target: self
				    selector: @selector(XMPP_stream:
						  didReadIntoBuffer:length:
						  exception:)
				     context: nil];

		return false;
	}

	return true;
}

- (bool)streamOpen
{
	return _streamOpen;
}

- (bool)checkCertificateAndGetReason: (OFString **)reason
{
	X509Certificate *cert;
	OFDictionary *SANs;
	bool serviceSpecific = false;

	@try {
		[_socket verifyPeerCertificate];
	} @catch (SSLInvalidCertificateException *e) {
		if (reason != NULL)
			*reason = [[[e reason] copy] autorelease];

		return false;
	}

	cert = [_socket peerCertificate];
	SANs = [cert subjectAlternativeName];

	if ([[SANs objectForKey: @"otherName"]
		objectForKey: OID_SRVName] != nil ||
	     [SANs objectForKey: @"dNSName"] != nil ||
	     [SANs objectForKey: @"uniformResourceIdentifier"] != nil)
		serviceSpecific = true;

	if ([cert hasSRVNameMatchingDomain: _domainToASCII
				   service: @"xmpp-client"] ||
	    [cert hasDNSNameMatchingDomain: _domainToASCII])
		return true;

	if (!serviceSpecific &&
	    [cert hasCommonNameMatchingDomain: _domainToASCII])
		return true;

	return false;
}

- (void)sendStanza: (OFXMLElement *)element
{
	[_delegates broadcastSelector: @selector(connection:didSendElement:)
			   withObject: self
			   withObject: element];

	[_socket writeString: [element XMLString]];
}

-   (void)sendIQ: (XMPPIQ *)IQ
  callbackTarget: (id)target
	selector: (SEL)selector
{
	void *pool = objc_autoreleasePoolPush();
	XMPPCallback *callback;
	OFString *ID, *key;

	if ((ID = [IQ ID]) == nil) {
		ID = [self generateStanzaID];
		[IQ setID: ID];
	}

	if ((key = [[IQ to] fullJID]) == nil)
		key = [_JID bareJID];
	if (key == nil) // Only happens for resource bind
		key = @"bind";
	key = [key stringByAppendingString: ID];

	callback = [XMPPCallback callbackWithTarget: target
					   selector: selector];
	[_callbacks setObject: callback
		       forKey: key];

	objc_autoreleasePoolPop(pool);

	[self sendStanza: IQ];
}

#ifdef OF_HAVE_BLOCKS
-  (void)sendIQ: (XMPPIQ *)IQ
  callbackBlock: (xmpp_callback_block_t)block
{
	void *pool = objc_autoreleasePoolPush();
	XMPPCallback *callback;
	OFString *ID, *key;

	if ((ID = [IQ ID]) == nil) {
		ID = [self generateStanzaID];
		[IQ setID: ID];
	}

	if ((key = [[IQ to] fullJID]) == nil)
		key = [_JID bareJID];
	if (key == nil) // Connection not yet bound, can't send stanzas
		@throw [OFInvalidArgumentException exception];
	key = [key stringByAppendingString: ID];

	callback = [XMPPCallback callbackWithBlock: block];
	[_callbacks setObject: callback
		       forKey: key];

	objc_autoreleasePoolPop(pool);

	[self sendStanza: IQ];
}
#endif

- (OFString *)generateStanzaID
{
	return [OFString stringWithFormat: @"objxmpp_%u", _lastID++];
}

-    (void)parser: (OFXMLParser *)parser
  didStartElement: (OFString *)name
	   prefix: (OFString *)prefix
	namespace: (OFString *)NS
       attributes: (OFArray *)attributes
{
	if (![name isEqual: @"stream"]) {
		// No dedicated stream error for this, may not even be XMPP
		[self close];
		[_socket close];
		return;
	}

	if (![prefix isEqual: @"stream"]) {
		[self XMPP_sendStreamError: @"bad-namespace-prefix"
				      text: nil];
		return;
	}

	if (![NS isEqual: XMPP_NS_STREAM]) {
		[self XMPP_sendStreamError: @"invalid-namespace"
				      text: nil];
		return;
	}

	for (OFXMLAttribute *attribute in attributes) {
		if ([[attribute name] isEqual: @"from"] &&
		    ![[attribute stringValue] isEqual: _domain]) {
			[self XMPP_sendStreamError: @"invalid-from"
					      text: nil];
			return;
		}
		if ([[attribute name] isEqual: @"version"] &&
		    ![[attribute stringValue] isEqual: @"1.0"]) {
			[self XMPP_sendStreamError: @"unsupported-version"
					      text: nil];
			return;
		}
	}

	[parser setDelegate: _elementBuilder];
}

- (void)elementBuilder: (OFXMLElementBuilder *)builder
       didBuildElement: (OFXMLElement *)element
{
	/* Ignore whitespace elements */
	if ([element name] == nil)
		return;

	[element setDefaultNamespace: XMPP_NS_CLIENT];
	[element setPrefix: @"stream"
	      forNamespace: XMPP_NS_STREAM];

	[_delegates broadcastSelector: @selector(connection:didReceiveElement:)
			   withObject: self
			   withObject: element];

	if ([[element namespace] isEqual: XMPP_NS_CLIENT])
		[self XMPP_handleStanza: element];

	if ([[element namespace] isEqual: XMPP_NS_STREAM])
		[self XMPP_handleStream: element];

	if ([[element namespace] isEqual: XMPP_NS_STARTTLS])
		[self XMPP_handleTLS: element];

	if ([[element namespace] isEqual: XMPP_NS_SASL])
		[self XMPP_handleSASL: element];
}

- (void)elementBuilder: (OFXMLElementBuilder *)builder
  didNotExpectCloseTag: (OFString *)name
		prefix: (OFString *)prefix
	     namespace: (OFString *)ns
{
	if (![name isEqual: @"stream"] || ![prefix isEqual: @"stream"] ||
	    ![ns isEqual: XMPP_NS_STREAM])
		@throw [OFMalformedXMLException exception];
	else {
		[self close];
	}
}

- (void)XMPP_startStream
{
	OFString *langString = @"";

	/* Make sure we don't get any old events */
	[_parser setDelegate: nil];
	[_elementBuilder setDelegate: nil];

	/*
	 * We can't release them now, as we are currently inside them. Release
	 * them the next time the parser returns.
	 */
	_oldParser = _parser;
	_oldElementBuilder = _elementBuilder;

	_parser = [[OFXMLParser alloc] init];
	[_parser setDelegate: self];

	_elementBuilder = [[XMPPXMLElementBuilder alloc] init];
	[_elementBuilder setDelegate: self];

	if (_language != nil)
		langString = [OFString stringWithFormat: @"xml:lang='%@' ",
							 _language];

	[_socket writeFormat: @"<?xml version='1.0'?>\n"
			      @"<stream:stream to='%@' "
			      @"xmlns='" XMPP_NS_CLIENT @"' "
			      @"xmlns:stream='" XMPP_NS_STREAM @"' %@"
			      @"version='1.0'>", _domain, langString];

	_streamOpen = true;
}

- (void)close
{
	if (_streamOpen)
		[_socket writeString: @"</stream:stream>"];


	[_oldParser release];
	_oldParser = nil;
	[_oldElementBuilder release];
	_oldElementBuilder = nil;
	[_authModule release];
	_authModule = nil;
	[_socket release];
	_socket = nil;
	[_JID release];
	_JID = nil;
	_streamOpen = _needsSession = _encrypted = false;
	_supportsRosterVersioning = _supportsStreamManagement = false;
	_lastID = 0;
}

- (void)XMPP_handleStanza: (OFXMLElement *)element
{
	if ([[element name] isEqual: @"iq"]) {
		[self XMPP_handleIQ: [XMPPIQ stanzaWithElement: element]];
		return;
	}

	if ([[element name] isEqual: @"message"]) {
		[self XMPP_handleMessage:
		    [XMPPMessage stanzaWithElement: element]];
		return;
	}

	if ([[element name] isEqual: @"presence"]) {
		[self XMPP_handlePresence:
		    [XMPPPresence stanzaWithElement: element]];
		return;
	}

	[self XMPP_sendStreamError: @"unsupported-stanza-type"
			      text: nil];
}


- (void)XMPP_handleStream: (OFXMLElement *)element
{
	if ([[element name] isEqual: @"features"]) {
		[self XMPP_handleFeatures: element];
		return;
	}

	if ([[element name] isEqual: @"error"]) {
		OFString *condition, *reason;
		[self close];
		[_socket close]; // Remote has already closed his stream

		if ([element elementForName: @"bad-format"
				  namespace: XMPP_NS_XMPP_STREAM])
			condition = @"bad-format";
		else if ([element elementForName: @"bad-namespace-prefix"
				       namespace: XMPP_NS_XMPP_STREAM])
			condition = @"bad-namespace-prefix";
		else if ([element elementForName: @"conflict"
				       namespace: XMPP_NS_XMPP_STREAM])
			condition = @"conflict";
		else if ([element elementForName: @"connection-timeout"
				       namespace: XMPP_NS_XMPP_STREAM])
			condition = @"connection-timeout";
		else if ([element elementForName: @"host-gone"
				       namespace: XMPP_NS_XMPP_STREAM])
			condition = @"host-gone";
		else if ([element elementForName: @"host-unknown"
				       namespace: XMPP_NS_XMPP_STREAM])
			condition = @"host-unknown";
		else if ([element elementForName: @"improper-addressing"
				       namespace: XMPP_NS_XMPP_STREAM])
			condition = @"improper-addressing";
		else if ([element elementForName: @"internal-server-error"
				       namespace: XMPP_NS_XMPP_STREAM])
			condition = @"internal-server-error";
		else if ([element elementForName: @"invalid-from"
				       namespace: XMPP_NS_XMPP_STREAM])
			condition = @"invalid-from";
		else if ([element elementForName: @"invalid-namespace"
				       namespace: XMPP_NS_XMPP_STREAM])
			condition = @"invalid-namespace";
		else if ([element elementForName: @"invalid-xml"
				       namespace: XMPP_NS_XMPP_STREAM])
			condition = @"invalid-xml";
		else if ([element elementForName: @"not-authorized"
				       namespace: XMPP_NS_XMPP_STREAM])
			condition = @"not-authorized";
		else if ([element elementForName: @"not-well-formed"
				       namespace: XMPP_NS_XMPP_STREAM])
			condition = @"not-well-formed";
		else if ([element elementForName: @"policy-violation"
				       namespace: XMPP_NS_XMPP_STREAM])
			condition = @"policy-violation";
		else if ([element elementForName: @"remote-connection-failed"
				       namespace: XMPP_NS_XMPP_STREAM])
			condition = @"remote-connection-failed";
		else if ([element elementForName: @"reset"
				       namespace: XMPP_NS_XMPP_STREAM])
			condition = @"reset";
		else if ([element elementForName: @"resource-constraint"
				       namespace: XMPP_NS_XMPP_STREAM])
			condition = @"resource-constraint";
		else if ([element elementForName: @"restricted-xml"
				       namespace: XMPP_NS_XMPP_STREAM])
			condition = @"restricted-xml";
		else if ([element elementForName: @"see-other-host"
				       namespace: XMPP_NS_XMPP_STREAM])
			condition = @"see-other-host";
		else if ([element elementForName: @"system-shutdown"
				       namespace: XMPP_NS_XMPP_STREAM])
			condition = @"system-shutdown";
		else if ([element elementForName: @"undefined-condition"
				       namespace: XMPP_NS_XMPP_STREAM])
			condition = @"undefined-condition";
		else if ([element elementForName: @"unsupported-encoding"
				       namespace: XMPP_NS_XMPP_STREAM])
			condition = @"unsupported-encoding";
		else if ([element elementForName: @"unsupported-feature"
				       namespace: XMPP_NS_XMPP_STREAM])
			condition = @"unsupported-feature";
		else if ([element elementForName: @"unsupported-stanza-type"
				       namespace: XMPP_NS_XMPP_STREAM])
			condition = @"unsupported-stanza-type";
		else if ([element elementForName: @"unsupported-version"
				       namespace: XMPP_NS_XMPP_STREAM])
			condition = @"unsupported-version";
		else
			condition = @"undefined";

		reason = [[element
		    elementForName: @"text"
			 namespace: XMPP_NS_XMPP_STREAM] stringValue];

		@throw [XMPPStreamErrorException
		    exceptionWithConnection: self
				  condition: condition
				     reason: reason];
		return;
	}

	assert(0);
}

- (void)XMPP_handleTLS: (OFXMLElement *)element
{
	if ([[element name] isEqual: @"proceed"]) {
		/* FIXME: Catch errors here */
		SSLSocket *newSock;

		[_delegates broadcastSelector: @selector(
						   connectionWillUpgradeToTLS:)
				   withObject: self];

		newSock = [[SSLSocket alloc] initWithSocket: _socket];
		[newSock setCertificateVerificationEnabled: false];
#if 0
		/* FIXME: Not yet implemented by ObjOpenSSL */
		[newSock setCertificateFile: _certificateFile];
		[newSock setPrivateKeyFile: _privateKeyFile];
		[newSock setPrivateKeyPassphrase: _privateKeyPassphrase];
#endif
		[newSock startTLSWithExpectedHost: nil];
		[_socket release];
		_socket = newSock;

		_encrypted = true;

		[_delegates broadcastSelector: @selector(
						   connectionDidUpgradeToTLS:)
				   withObject: self];

		/* Stream restart */
		[self XMPP_startStream];

		return;
	}

	if ([[element name] isEqual: @"failure"])
		/* TODO: Find/create an exception to throw here */
		@throw [OFException exception];

	assert(0);
}

- (void)XMPP_handleSASL: (OFXMLElement *)element
{
	if ([[element name] isEqual: @"challenge"]) {
		OFXMLElement *responseTag;
		OFData *challenge =
		    [OFData dataWithBase64EncodedString: [element stringValue]];
		OFData *response = [_authModule continueWithData: challenge];

		responseTag = [OFXMLElement elementWithName: @"response"
						  namespace: XMPP_NS_SASL];
		if (response) {
			if ([response count] == 0)
				[responseTag setStringValue: @"="];
			else
				[responseTag setStringValue:
				    [response stringByBase64Encoding]];
		}

		[self sendStanza: responseTag];
		return;
	}

	if ([[element name] isEqual: @"success"]) {
		[_authModule continueWithData: [OFData
		    dataWithBase64EncodedString: [element stringValue]]];

		[_delegates broadcastSelector: @selector(
						   connectionWasAuthenticated:)
				   withObject: self];

		/* Stream restart */
		[self XMPP_startStream];

		return;
	}

	if ([[element name] isEqual: @"failure"]) {
		/* FIXME: Do more parsing/handling */
		@throw [XMPPAuthFailedException
		    exceptionWithConnection: self
				     reason: [element XMLString]];
	}

	assert(0);
}

- (void)XMPP_handleIQ: (XMPPIQ *)IQ
{
	bool handled = false;
	XMPPCallback *callback;
	OFString *key;

	if ((key = [[IQ from] fullJID]) == nil)
		key = [_JID bareJID];
	if (key == nil) // Only happens for resource bind
		key = @"bind";
	key = [key stringByAppendingString: [IQ ID]];

	if ((callback = [_callbacks objectForKey: key])) {
		[callback runWithIQ: IQ
			 connection: self];
		[_callbacks removeObjectForKey: key];
		return;
	}

	handled = [_delegates broadcastSelector: @selector(
						     connection:didReceiveIQ:)
				     withObject: self
				     withObject: IQ];

	if (!handled && ![[IQ type] isEqual: @"error"] &&
	    ![[IQ type] isEqual: @"result"]) {
		[self sendStanza: [IQ errorIQWithType: @"cancel"
					    condition: @"service-unavailable"]];
	}
}

- (void)XMPP_handleMessage: (XMPPMessage *)message
{
	[_delegates broadcastSelector: @selector(connection:didReceiveMessage:)
			   withObject: self
			   withObject: message];
}

- (void)XMPP_handlePresence: (XMPPPresence *)presence
{
	[_delegates broadcastSelector: @selector(connection:didReceivePresence:)
			   withObject: self
			   withObject: presence];
}

- (void)XMPP_handleFeatures: (OFXMLElement *)element
{
	OFXMLElement *startTLS = [element elementForName: @"starttls"
					       namespace: XMPP_NS_STARTTLS];
	OFXMLElement *bind = [element elementForName: @"bind"
					   namespace: XMPP_NS_BIND];
	OFXMLElement *session = [element elementForName: @"session"
					      namespace: XMPP_NS_SESSION];
	OFXMLElement *mechs = [element elementForName: @"mechanisms"
					    namespace: XMPP_NS_SASL];
	OFMutableSet *mechanisms = [OFMutableSet set];

	if (!_encrypted && startTLS != nil) {
		[self sendStanza:
		    [OFXMLElement elementWithName: @"starttls"
					namespace: XMPP_NS_STARTTLS]];
		return;
	}

	if (_encryptionRequired && !_encrypted)
		/* TODO: Find/create an exception to throw here */
		@throw [OFException exception];

	if ([element elementForName: @"ver"
			  namespace: XMPP_NS_ROSTERVER] != nil)
		_supportsRosterVersioning = true;

	if ([element elementForName: @"sm"
			  namespace: XMPP_NS_SM] != nil)
		_supportsStreamManagement = true;

	if (mechs != nil) {
		OFEnumerator *enumerator;
		OFXMLElement *mech;

		enumerator = [[mechs children] objectEnumerator];
		while ((mech = [enumerator nextObject]) != nil)
			[mechanisms addObject: [mech stringValue]];

		if (_privateKeyFile != nil && _certificateFile != nil &&
		    [mechanisms containsObject: @"EXTERNAL"]) {
			_authModule = [[XMPPEXTERNALAuth alloc] init];
			[self XMPP_sendAuth: @"EXTERNAL"];
			return;
		}

		if ([mechanisms containsObject: @"SCRAM-SHA-1-PLUS"]) {
			_authModule = [[XMPPSCRAMAuth alloc]
			    initWithAuthcid: _username
				   password: _password
				 connection: self
				       hash: [OFSHA1Hash class]
			      plusAvailable: true];
			[self XMPP_sendAuth: @"SCRAM-SHA-1-PLUS"];
			return;
		}

		if ([mechanisms containsObject: @"SCRAM-SHA-1"]) {
			_authModule = [[XMPPSCRAMAuth alloc]
			    initWithAuthcid: _username
				   password: _password
				 connection: self
				       hash: [OFSHA1Hash class]
			      plusAvailable: false];
			[self XMPP_sendAuth: @"SCRAM-SHA-1"];
			return;
		}

		if ([mechanisms containsObject: @"PLAIN"] && _encrypted) {
			_authModule = [[XMPPPLAINAuth alloc]
			    initWithAuthcid: _username
				   password: _password];
			[self XMPP_sendAuth: @"PLAIN"];
			return;
		}

		assert(0);
	}

	if (session != nil && [session elementForName: @"optional"
					    namespace: XMPP_NS_SESSION] == nil)
		_needsSession = true;

	if (bind != nil) {
		[self XMPP_sendResourceBind];
		return;
	}

	assert(0);
}

- (void)XMPP_sendAuth: (OFString *)authName
{
	OFXMLElement *authTag;
	OFData *initialMessage = [_authModule initialMessage];

	authTag = [OFXMLElement elementWithName: @"auth"
				      namespace: XMPP_NS_SASL];
	[authTag addAttributeWithName: @"mechanism"
			  stringValue: authName];
	if (initialMessage) {
		if ([initialMessage count] == 0)
			[authTag setStringValue: @"="];
		else
			[authTag setStringValue:
			    [initialMessage stringByBase64Encoding]];
	}

	[self sendStanza: authTag];
}

- (void)XMPP_sendResourceBind
{
	XMPPIQ *IQ;
	OFXMLElement *bind;

	IQ = [XMPPIQ IQWithType: @"set"
			     ID: [self generateStanzaID]];

	bind = [OFXMLElement elementWithName: @"bind"
				   namespace: XMPP_NS_BIND];

	if (_resource != nil)
		[bind addChild: [OFXMLElement elementWithName: @"resource"
						    namespace: XMPP_NS_BIND
						  stringValue: _resource]];

	[IQ addChild: bind];

	[self	    sendIQ: IQ
	    callbackTarget: self
		  selector: @selector(XMPP_handleResourceBindForConnection:
				IQ:)];
}

- (void)XMPP_sendStreamError: (OFString *)condition
			text: (OFString *)text
{
	OFXMLElement *error = [OFXMLElement
	    elementWithName: @"error"
		  namespace: XMPP_NS_STREAM];
	[error setPrefix: @"stream"
	    forNamespace: XMPP_NS_STREAM];
	[error addChild: [OFXMLElement elementWithName: condition
					     namespace: XMPP_NS_XMPP_STREAM]];
	if (text)
		[error addChild: [OFXMLElement
		    elementWithName: @"text"
			  namespace: XMPP_NS_XMPP_STREAM
			stringValue: text]];
	[_parser setDelegate: nil];
	[self sendStanza: error];
	[self close];
}

- (void)XMPP_handleResourceBindForConnection: (XMPPConnection *)connection
					  IQ: (XMPPIQ *)IQ
{
	OFXMLElement *bindElement, *JIDElement;

	assert([[IQ type] isEqual: @"result"]);

	bindElement = [IQ elementForName: @"bind"
			       namespace: XMPP_NS_BIND];

	assert(bindElement != nil);

	JIDElement = [bindElement elementForName: @"jid"
				       namespace: XMPP_NS_BIND];
	_JID = [[XMPPJID alloc] initWithString: [JIDElement stringValue]];

	if (_needsSession) {
		[self XMPP_sendSession];
		return;
	}

	[_delegates broadcastSelector: @selector(connection:wasBoundToJID:)
			   withObject: self
			   withObject: _JID];
}

- (void)XMPP_sendSession
{
	XMPPIQ *IQ = [XMPPIQ IQWithType: @"set"
				     ID: [self generateStanzaID]];

	[IQ addChild: [OFXMLElement elementWithName: @"session"
					  namespace: XMPP_NS_SESSION]];

	[self	    sendIQ: IQ
	    callbackTarget: self
		  selector: @selector(XMPP_handleSessionForConnection:IQ:)];
}

- (void)XMPP_handleSessionForConnection: (XMPPConnection *)connection
				     IQ: (XMPPIQ *)IQ
{
	if (![[IQ type] isEqual: @"result"])
		OF_ENSURE(0);

	[_delegates broadcastSelector: @selector(connection:wasBoundToJID:)
			   withObject: self
			   withObject: _JID];
}

- (OFString *)XMPP_IDNAToASCII: (OFString *)domain
{
	OFString *ret;
	char *cDomain;
	Idna_rc rc;

	if ((rc = idna_to_ascii_8z([domain UTF8String],
	    &cDomain, IDNA_USE_STD3_ASCII_RULES)) != IDNA_SUCCESS)
		@throw [XMPPIDNATranslationFailedException
		    exceptionWithConnection: self
				  operation: @"ToASCII"
				     string: domain];

	@try {
		ret = [[OFString alloc] initWithUTF8String: cDomain];
	} @finally {
		free(cDomain);
	}

	return ret;
}

- (void)setDataStorage: (id <XMPPStorage>)dataStorage
{
	if (_streamOpen)
		/* FIXME: Find a better exception! */
		@throw [OFInvalidArgumentException exception];

	_dataStorage = dataStorage;
}

- (id <XMPPStorage>)dataStorage
{
	return _dataStorage;
}

- (void)addDelegate: (id <XMPPConnectionDelegate>)delegate
{
	[_delegates addDelegate: delegate];
}

- (void)removeDelegate: (id <XMPPConnectionDelegate>)delegate
{
	[_delegates removeDelegate: delegate];
}

- (XMPPMulticastDelegate *)XMPP_delegates
{
	return _delegates;
}
@end
