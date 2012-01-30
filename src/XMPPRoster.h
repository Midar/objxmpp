/*
 * Copyright (c) 2011, Jonathan Schleifer <js@webkeks.org>
 * Copyright (c) 2012, Florian Zeitz <florob@babelmonkeys.de>
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

#import "XMPPConnection.h"

@class XMPPRosterItem;
@class XMPPIQ;
@class XMPPRoster;
@class XMPPMulticastDelegate;

@protocol XMPPRosterDelegate
#ifndef XMPP_ROSTER_M
    <OFObject>
#endif
#ifdef OF_HAVE_OPTIONAL_PROTOCOLS
@optional
#endif
- (void)rosterWasReceived: (XMPPRoster*)roster;
-         (void)roster: (XMPPRoster*)roster
  didReceiveRosterItem: (XMPPRosterItem*)rosterItem;
@end


@interface XMPPRoster: OFObject
#ifdef OF_HAVE_OPTIONAL_PROTOCOLS
    <XMPPConnectionDelegate>
#endif
{
	XMPPConnection *connection;
	OFMutableDictionary *rosterItems;
	XMPPMulticastDelegate *delegates;
}

- initWithConnection: (XMPPConnection*)conn;
- (OFDictionary*)rosterItems;
- (void)requestRoster;
- (void)addRosterItem: (XMPPRosterItem*)rosterItem;
- (void)updateRosterItem: (XMPPRosterItem*)rosterItem;
- (void)deleteRosterItem: (XMPPRosterItem*)rosterItem;
- (void)addDelegate: (id <XMPPRosterDelegate>)delegate;
- (void)removeDelegate: (id <XMPPRosterDelegate>)delegate;
- (void)XMPP_addRosterItem: (XMPPRosterItem*)rosterItem;
- (void)XMPP_updateRosterItem: (XMPPRosterItem*)rosterItem;
- (void)XMPP_deleteRosterItem: (XMPPRosterItem*)rosterItem;
- (void)XMPP_handleInitialRoster: (XMPPIQ*)iq;
- (XMPPRosterItem*)XMPP_rosterItemWithXMLElement: (OFXMLElement*)element;
@end

@interface OFObject (XMPPRosterDelegate) <XMPPRosterDelegate>
@end
