#import "SSHTunnel.h"

#import "PreferenceController.h"
#import "TokenController.h"

#ifndef NSAppKitVersionNumber10_3
#define NSAppKitVersionNumber10_3 743
#endif

@implementation SSHTunnel

- (id)init
{
	if(self = [super init])
	{
		tunnelHost = nil;
		tunnelPort = 0;
		tunnelUser = nil;

		localPortForwards = [[NSMutableArray alloc] init];
		remotePortForwards = [[NSMutableArray alloc] init];
		dynamicPortForwards = [[NSMutableArray alloc] init];
		
		closeSelector = nil;
		closeObject = nil;
		closeInfo = nil;

		compression = NO;
		
		tunnel = nil;
		thePipe = nil;
	}

	return self;
}

- (void)dealloc
{
	[localPortForwards release];
	[remotePortForwards release];
	[dynamicPortForwards release];
	[tunnelHost release];
	[tunnelUser release];
	[tunnel release];
	[thePipe release];
	
	[super dealloc];
}

/* Set the tunnel host, port and user. */
- (BOOL)setTunnelHost:(NSString *)host withPort:(int)port andUser:(NSString *)user
{
	if (open)
		return NO;
	
	NSString *oldHost = tunnelHost;
	tunnelHost = [host copy];
	[oldHost release];
	tunnelPort = port;
	
	NSString *oldUser = tunnelUser;
	tunnelUser = [user copy];
	[oldUser release];

	return YES;
}

/* Set compression. */
- (BOOL)setCompression:(BOOL)theBool
{
	if (open)
		return NO;

	compression = theBool;
	return YES;
}

/* Set remote access. */
- (BOOL)setRemoteAccess:(BOOL)theBool
{
	if (open)
		return NO;
	
	remoteAccess = theBool;
	return YES;
}

/* Add a local port forward. */
- (BOOL)addLocalPortForwardWithPort:(int)lport remoteHost:(NSString *)rhost remotePort:(int)rport
{
	if (open || lport < 1 || lport > 65535 || rport < 1 || rport > 65535)
		return NO;

	[localPortForwards addObject:[NSArray arrayWithObjects:[NSNumber numberWithInt:lport], rhost, [NSNumber numberWithInt:rport], nil]];
	return YES;
}

/* Add a remote port forward. */
- (BOOL)addRemotePortForwardWithPort:(int)rport localHost:(NSString *)lhost localPort:(int)lport
{
	if (open || lport < 1 || lport > 65535 || rport < 1 || rport > 65535)
		return NO;

	[remotePortForwards addObject:[NSArray arrayWithObjects:[NSNumber numberWithInt:rport], lhost, [NSNumber numberWithInt:lport], nil]];
	return YES;
}

/* Add a dynamic port forward. */
- (BOOL)addDynamicPortForwardWithPort:(int)lport
{
	if (open || lport < 1 || lport > 65535)
		return NO;
	
	[dynamicPortForwards addObject:[NSNumber numberWithInt:lport]];
	return YES;
}

/* Get the output after the task has finished. */
- (NSString *)getOutput
{
	return [[[NSString alloc] initWithData:[[thePipe fileHandleForReading] readDataToEndOfFile] encoding:NSUTF8StringEncoding] autorelease];
}

/* Handle closed tunnel notifications. */
- (void)handleClosedWithSelector:(SEL)theSelector toObject:(id)theObject withInfo:(id)theInfo
{

	if (!theSelector || !theObject)
		return;
	
	closeSelector = theSelector;
	closeObject = theObject;
	
	if (theInfo)
		closeInfo = theInfo;
	else
		closeInfo = nil;
}

/* Return YES if the tunnel is open, and NO if not. */
- (BOOL)isOpen
{
	return open;
}

- (BOOL)openTunnel
{

	if ([self isOpen])
		return NO;

	if (!tunnelHost || [tunnelHost isEqualToString:@""])
		return NO;

	open = YES;

	/* Initialize a ssh SSHTool, and set the arguments. */
	tunnel = [[SSHTool toolWithPath:[[[NSBundle mainBundle] resourcePath] 
			stringByAppendingPathComponent:@"TunnelRunner"]] retain];

	
	/*  We want to use our internal build of ssh if we have dynamic ports and the SSHToolsPathString
		is /usr/bin. This is because the Panther-provided copy of ssh (and perhaps Jaguar-provided,
		I don't know) is broken wrt. dynamic ports */
	// Of course, since the build of ssh only works on Panther, we have to disable Dynamic Ports
	// entirely under Jaguar
	// SSH under Tiger works fine. Don't use the workaround then
	NSString *toolPath;
	NSString *sshPathString = [[NSUserDefaults standardUserDefaults] stringForKey:SSHToolsPathString];
	if (floor(NSAppKitVersionNumber) != NSAppKitVersionNumber10_3)
		// It's not Panther (i.e. either Jaguar or Tiger)
		toolPath = [sshPathString stringByAppendingPathComponent:@"ssh"];
	else if([dynamicPortForwards count] > 0 && [[sshPathString stringByStandardizingPath] isEqualToString:@"/usr/bin"])
	
		/* Time to use our internal build */
		toolPath = [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:@"ssh"];
	else
		toolPath = [sshPathString stringByAppendingPathComponent:@"ssh"];

	NSMutableArray *arguments = [NSMutableArray arrayWithObject:toolPath];
	NSEnumerator *e = [localPortForwards objectEnumerator];
	NSArray *portForward;
	while (portForward = [e nextObject])
	{
		[arguments addObject:[NSString stringWithFormat:@"-L%d:%@:%d", [[portForward objectAtIndex:0] intValue], 
									       [portForward objectAtIndex:1],
									       [[portForward objectAtIndex:2] intValue]]
			];
	}
	
	e = [remotePortForwards objectEnumerator];
	while (portForward = [e nextObject])
	{
		[arguments addObject:[NSString stringWithFormat:@"-R%d:%@:%d", [[portForward objectAtIndex:0] intValue], 
									       [portForward objectAtIndex:1],
									       [[portForward objectAtIndex:2] intValue]]
			];
	}
	
	// No dynamic ports under Jaguar
	if (floor(NSAppKitVersionNumber) > NSAppKitVersionNumber10_2)
	{
		e = [dynamicPortForwards objectEnumerator];
		NSNumber *dynamicPortForward;
		while (dynamicPortForward = [e nextObject])
		{
			[arguments addObject:@"-D"];

			/* A bit awkward, but it makes sure a number is given. */
			[arguments addObject:[NSString stringWithFormat:@"%d", [dynamicPortForward intValue]]];
		}
	}

	if (tunnelPort > 0 && tunnelPort < 65535)
	{
		[arguments addObject:@"-p"];
		[arguments addObject:[NSString stringWithFormat:@"%d", tunnelPort]];
	}

	[arguments addObject:@"-N"];
	[arguments addObject:@"-t"];
	[arguments addObject:@"-x"];

	if (compression)
		[arguments addObject:@"-C"];
	
	if (remoteAccess)
		[arguments addObject:@"-g"];
	
	[arguments addObject:@"-o"];
	[arguments addObject:@"PreferredAuthentications=hostbased,publickey,password,keyboard-interactive"];
	
	if (tunnelUser && ![tunnelUser isEqualToString:@""])
		[arguments addObject:[NSString stringWithFormat:@"%@@%@", tunnelUser, tunnelHost]];

	else
		[arguments addObject:[NSString stringWithFormat:@"%@", tunnelHost]];
		
	[tunnel setArguments:arguments];
	
	/* Set the SSH_ASKPASS + DISPLAY environment variables, so the tool can ask for a passphrase. */
	[tunnel setEnvironmentVariable:@"SSH_ASKPASS" withValue:
		[[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:@"PassphraseRequester"]];
	
	[tunnel setEnvironmentVariable:@"DISPLAY" withValue:@":0"];
	[tunnel setEnvironmentVariable:@"INTERACTION" withValue:@"1"];
	[tunnel setEnvironmentVariable:@"SSH_AUTH_SOCK" 
			     withValue:[[NSUserDefaults standardUserDefaults] stringForKey:SocketPathString]];

	if (closeSelector && closeObject)
		[tunnel handleTerminateWithSelector:closeSelector toObject:closeObject withInfo:closeInfo];
	
	thePipe = [[NSPipe alloc] init];

	[[tunnel task] setStandardOutput:thePipe];

	// Generate a token.
	if (![[TokenController sharedController] generateNewTokenForTool:tunnel])
	{
		return NO;
	}
	
	/* Launch ssh. */
	if (![tunnel launch])
		return NO;
	
	open = YES;
	return YES;
}

- (void)closeTunnel
{	
	if (open && tunnel)
	{	
		SSHTool *killTunnel = [[SSHTool toolWithPath:[[[NSBundle mainBundle] resourcePath] 
			stringByAppendingPathComponent:@"TunnelRunner"]] retain];
		[killTunnel setArguments:[NSArray arrayWithObjects:@"-k", [NSString stringWithFormat:@"%d", [[tunnel task] processIdentifier]], nil]];
		[killTunnel launch];
	}

	[tunnel release];
	tunnel = nil;
	[thePipe release];
	thePipe = nil;
}

@end
