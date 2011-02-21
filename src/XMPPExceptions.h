/*
 * Copyright (c) 2011, Jonathan Schleifer <js@webkeks.org>
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
@class XMPPAuthenticator;

@interface XMPPException: OFException
{
	XMPPConnection *connection;
}

@property (readonly, nonatomic) XMPPConnection *connection;

+ newWithClass: (Class)class_
    connection: (XMPPConnection*)conn;
- initWithClass: (Class)class_
     connection: (XMPPConnection*)conn;
@end

@interface XMPPStringPrepFailedException: XMPPException
{
	OFString *profile;
	OFString *string;
}

@property (readonly, nonatomic) OFString *profile, *string;

+ newWithClass: (Class)class_
    connection: (XMPPConnection*)conn
       profile: (OFString*)profile
	string: (OFString*)string;
- initWithClass: (Class)class_
     connection: (XMPPConnection*)conn
	profile: (OFString*)profile
	 string: (OFString*)string;
@end

@interface XMPPIDNATranslationFailedException: XMPPException
{
	OFString *operation;
	OFString *string;
}

@property (readonly, nonatomic) OFString *operation, *string;

+ newWithClass: (Class)class_
    connection: (XMPPConnection*)conn
     operation: (OFString*)operation
	string: (OFString*)string;
- initWithClass: (Class)class_
     connection: (XMPPConnection*)conn
      operation: (OFString*)operation
	 string: (OFString*)string;
@end

@interface XMPPAuthFailedException: XMPPException
{
	OFString *reason;
}

@property (readonly, nonatomic) OFString *reason;

+ newWithClass: (Class)class_
    connection: (XMPPConnection*)conn
	reason: (OFString*)reason_;
- initWithClass: (Class)class_
     connection: (XMPPConnection*)conn
	 reason: (OFString*)reason_;
@end
