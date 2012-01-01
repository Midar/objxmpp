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

#import <ObjFW/ObjFW.h>

@class XMPPConnection;
@class XMPPJID;
@class XMPPIQ;
@class XMPPMessage;
@class XMPPPresence;
@class XMPPAuthenticator;
@class XMPPRoster;
@class XMPPRosterItem;
@class SSLSocket;

@protocol XMPPConnectionDelegate
#ifndef XMPP_CONNECTION_M
    <OFObject>
#endif
#ifdef OF_HAVE_OPTIONAL_PROTOCOLS
@optional
#endif
-  (void)connection: (XMPPConnection*)connection
  didReceiveElement: (OFXMLElement*)element;
- (void)connection: (XMPPConnection*)connection
    didSendElement: (OFXMLElement*)element;
- (void)connectionWasAuthenticated: (XMPPConnection*)connection;
- (void)connection: (XMPPConnection*)connection
     wasBoundToJID: (XMPPJID*)JID;
- (void)connectionDidReceiveRoster: (XMPPConnection*)connection;
- (BOOL)connection: (XMPPConnection*)connection
      didReceiveIQ: (XMPPIQ*)iq;
-   (void)connection: (XMPPConnection*)connection
  didReceivePresence: (XMPPPresence*)presence;
-  (void)connection: (XMPPConnection*)connection
  didReceiveMessage: (XMPPMessage*)message;
-     (void)connection: (XMPPConnection*)connection
  didReceiveRosterItem: (XMPPRosterItem*)rosterItem;
- (void)connectionWasClosed: (XMPPConnection*)connection;
- (void)connectionWillUpgradeToTLS: (XMPPConnection*)connection;
- (void)connectionDidUpgradeToTLS: (XMPPConnection*)connection;
@end

/**
 * \brief A class which abstracts a connection to an XMPP service.
 */
@interface XMPPConnection: OFObject
#ifdef OF_HAVE_OPTONAL_PROTOCOLS
    <OFXMLParserDelegate, OFXMLElementBuilderDelegate>
#endif
{
	id sock;
	OFXMLParser *parser, *oldParser;
	OFXMLElementBuilder *elementBuilder, *oldElementBuilder;
	OFString *username, *password, *server, *resource;
	OFString *domain, *domainToASCII;
	XMPPJID *JID;
	uint16_t port;
	id <XMPPConnectionDelegate, OFObject> delegate;
	OFMutableDictionary *callbacks;
	XMPPAuthenticator *authModule;
	BOOL needsSession;
	BOOL encryptionRequired, encrypted;
	unsigned int lastID;
	XMPPRoster *roster;
}

#ifdef OF_HAVE_PROPERTIES
@property (copy) OFString *username, *password, *server, *domain, *resource;
@property (copy, readonly) XMPPJID *JID;
@property (assign) uint16_t port;
@property (assign) id <XMPPConnectionDelegate> delegate;
@property (readonly, retain) XMPPRoster *roster;
@property (readonly, retain, getter=socket) OFTCPSocket *sock;
@property (assign) BOOL encryptionRequired;
@property (readonly) BOOL encrypted;
#endif

/**
 * \return A new autoreleased XMPPConnection
 */
+ connection;

/**
 * Connects to the XMPP service.
 */
- (void)connect;

/**
 * Checks the certificate presented by the server.
 * Throws SSLInvalidCertificateException on failure.
 */
- (void)checkCertificate;

/**
 * Starts a loop handling incomming data.
 */
- (void)handleConnection;

/**
 * Parses the specified buffer.
 *
 * This is useful for handling multiple connections at once.
 *
 * \param buffer The buffer to parse
 * \param length The length of the buffer. If length is 0, it is assumed that
 *		 the connection was closed.
 */
- (void)parseBuffer: (const char*)buffer
	 withLength: (size_t)length;

/**
 * \return The socket used by the XMPPConnection
 */
- (OFTCPSocket*)socket;

/**
 * \return Whether encryption is encrypted
 */
- (BOOL)encryptionRequired;

/**
 * Sets whether encryption is required.
 *
 * \param required Whether encryption is required
 */
- (void)setEncryptionRequired: (BOOL)required;

/**
 * \return Whether the connection is encrypted
 */
- (BOOL)encrypted;

/**
 * Sends an OFXMLElement, usually an XMPPStanza.
 *
 * \param element The element to send
 */
- (void)sendStanza: (OFXMLElement*)element;

/**
 * Sends an XMPPIQ, registering a callback method
 *
 * \param object The object that contains the callback method
 * \param selector The selector of the callback method,
 *		   must take exactly one parameter of type XMPPIQ*
 */
-     (void)sendIQ: (XMPPIQ*)iq
withCallbackObject: (id)object
	  selector: (SEL)selector;

#ifdef OF_HAVE_BLOCKS
/**
 * Sends an XMPPIQ, registering a callback block
 *
 * \param callback The callback block
 */
-    (void)sendIQ: (XMPPIQ*)iq
withCallbackBlock: (void(^)(XMPPIQ*))callback;
#endif

/**
 * Generates a new, unique stanza ID.
 *
 * \return A new, generated, unique stanza ID.
 */
- (OFString*)generateStanzaID;

- (void)setUsername: (OFString*)username;
- (OFString*)username;
- (void)setPassword: (OFString*)password;
- (OFString*)password;
- (void)setServer: (OFString*)server;
- (OFString*)server;
- (void)setDomain: (OFString*)domain;
- (OFString*)domain;
- (void)setResource: (OFString*)resource;
- (OFString*)resource;
- (XMPPJID*)JID;
- (void)setPort: (uint16_t)port;
- (uint16_t)port;
- (void)setDelegate: (id <XMPPConnectionDelegate>)delegate;
- (id <XMPPConnectionDelegate>)delegate;
- (XMPPRoster*)roster;

- (void)XMPP_startStream;
- (void)XMPP_handleStream: (OFXMLElement*)element;
- (void)XMPP_handleTLS: (OFXMLElement*)element;
- (void)XMPP_handleSASL: (OFXMLElement*)element;
- (void)XMPP_handleStanza: (OFXMLElement*)element;
- (void)XMPP_sendAuth: (OFString*)authName;
- (void)XMPP_handleIQ: (XMPPIQ*)iq;
- (void)XMPP_handleMessage: (XMPPMessage*)message;
- (void)XMPP_handlePresence: (XMPPPresence*)presence;
- (void)XMPP_handleFeatures: (OFXMLElement*)element;
- (void)XMPP_sendResourceBind;
- (void)XMPP_handleResourceBind: (XMPPIQ*)iq;
- (void)XMPP_sendSession;
- (void)XMPP_handleSession: (XMPPIQ*)iq;
- (OFString*)XMPP_IDNAToASCII: (OFString*)domain;
@end

@interface OFObject (XMPPConnectionDelegate) <XMPPConnectionDelegate>
@end
