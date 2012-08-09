/*
 * Copyright (c) 2012, Florian Zeitz <florob@babelmonkeys.de>
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

#import "XMPPStreamManagement.h"
#import "namespaces.h"

@implementation XMPPStreamManagement
- initWithConnection: (XMPPConnection*)connection_
{
	self = [super init];

	@try {
		connection = connection_;
		[connection addDelegate: self];
		receivedCount = 0;
	} @catch (id e) {
		[self release];
		@throw e;
	}

	return self;
}

- (void)dealloc
{
	[connection removeDelegate: self];

	[super dealloc];
}

- (void)connection: (XMPPConnection*)connection_
 didReceiveElement: (OFXMLElement*)element
{
	OFString *elementName = [element name];
	OFString *elementNS = [element namespace];

	if ([elementNS isEqual: XMPP_NS_SM]) {
		if ([elementName isEqual: @"enabled"]) {
			receivedCount = 0;
			return;
		}

		if ([elementName isEqual: @"failed"]) {
			/* TODO: How do we handle this? */
			return;
		}

		if ([elementName isEqual: @"r"]) {
			OFXMLElement *ack =
			    [OFXMLElement elementWithName: @"a"
						namespace: XMPP_NS_SM];
			[ack addAttributeWithName: @"h"
				      stringValue:
			    [OFString stringWithFormat: @"%" PRIu32,
				receivedCount]];
			[connection_ sendStanza: ack];
		}
	}

	if ([elementNS isEqual: XMPP_NS_CLIENT] &&
	    ([elementName isEqual: @"iq"] ||
	     [elementName isEqual: @"presence"] ||
	     [elementName isEqual: @"message"]))
		receivedCount++;
}

/* TODO: Count outgoing stanzas here and cache them, send own ACK requests
- (void)connection: (XMPPConnection*)connection_
    didSendElement: (OFXMLElement*)element
{
}
*/

- (void)connection: (XMPPConnection*)connection_
     wasBoundToJID: (XMPPJID*)jid
{
	if ([connection_ supportsStreamManagement])
		[connection_ sendStanza:
		    [OFXMLElement elementWithName: @"enable"
					namespace: XMPP_NS_SM]];
}
@end