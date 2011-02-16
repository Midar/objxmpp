#import <ObjFW/ObjFW.h>

#import "XMPPJID.h"

@class XMPPConnection;
@class XMPPIQ;
@class XMPPMessage;
@class XMPPPresence;

@protocol XMPPConnectionDelegate
- (void)connectionWasClosed: (XMPPConnection*)conn;
- (void)connection: (XMPPConnection*)conn
      didReceiveIQ: (XMPPIQ*)iq;
-   (void)connection: (XMPPConnection*)conn
  didReceivePresence: (XMPPPresence*)pres;
-  (void)connection: (XMPPConnection*)conn
  didReceiveMessage: (XMPPMessage*)msg;
@end

/**
 * \brief A class that abstracts a connection to an XMPP service
 */
@interface XMPPConnection: OFObject <OFXMLElementBuilderDelegate>
{
	OFTCPSocket *sock;
	OFXMLParser *parser;
	OFXMLElementBuilder *elementBuilder;

	/**
	 * The username to connect with
	 */
	OFString *username;

	/**
	 * The password to connect with
	 */
	OFString *password;

	/**
	 * The server to connect to
	 */
	OFString *server;

	/**
	 * The resource to connect with
	 */
	OFString *resource;

	/**
	 * The JID bound to this connection (this is determined by the server)
	 */
	XMPPJID *JID;

	/**
	 * The port to connect to
	 */
	short port;

	/**
	 * Whether to use TLS
	 */
	BOOL useTLS;
	id <XMPPConnectionDelegate> delegate;
	OFMutableArray *mechanisms;
}

@property (copy) OFString *username;
@property (copy) OFString *password;
@property (copy) OFString *server;
@property (copy) OFString *resource;
@property (readonly) XMPPJID *JID;
@property (assign) short port;
@property (assign) BOOL useTLS;
@property (retain) id <XMPPConnectionDelegate> delegate;

/**
 * Connects to the XMPP service
 */
- (void)connect;

/**
 * Starts a loop handling incomming data
 */
- (void)handleConnection;

/**
 * Sends a OFXMLElement (usually a XMPPStanza)
 *
 * \param elem The element to send
 */
- (void)sendStanza: (OFXMLElement*)elem;
@end