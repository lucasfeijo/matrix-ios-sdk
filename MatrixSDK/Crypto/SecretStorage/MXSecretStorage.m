/*
 Copyright 2020 The Matrix.org Foundation C.I.C
 
 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at
 
 http://www.apache.org/licenses/LICENSE-2.0
 
 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
 */

#import "MXSecretStorage_Private.h"

#import "MXSession.h"
#import "MXTools.h"
#import "MXKeyBackupPassword.h"
#import "MXRecoveryKey.h"
#import "MXHkdfSha256.h"
#import "MXAesHmacSha2.h"
#import "MXBase64Tools.h"
#import <OLMKit/OLMKit.h>
#import "MXEncryptedSecretContent.h"


#pragma mark - Constants

NSString *const MXSecretStorageErrorDomain = @"org.matrix.sdk.MXSecretStorage";
static NSString* const kSecretStorageKeyIdFormat = @"m.secret_storage.key.%@";



@interface MXSecretStorage ()
{
    // The queue to run background tasks
    dispatch_queue_t processingQueue;
}

@property (nonatomic, readonly, weak) MXSession *mxSession;

@end


@implementation MXSecretStorage


#pragma mark - SDK-Private methods -

- (instancetype)initWithMatrixSession:(MXSession *)mxSession processingQueue:(dispatch_queue_t)aProcessingQueue
{
    self = [super init];
    if (self)
    {
        _mxSession = mxSession;
        processingQueue = aProcessingQueue;
    }
    return self;
}


#pragma mark - Public methods -

#pragma mark - Secret Storage Key

- (MXHTTPOperation*)createKeyWithKeyId:(nullable NSString*)keyId
                               keyName:(nullable NSString*)keyName
                            passphrase:(nullable NSString*)passphrase
                               success:(void (^)(MXSecretStorageKeyCreationInfo *keyCreationInfo))success
                               failure:(void (^)(NSError *error))failure
{
    keyId = keyId ?: [[NSUUID UUID] UUIDString];
    
    MXHTTPOperation *operation = [MXHTTPOperation new];
    
    MXWeakify(self);
    dispatch_async(processingQueue, ^{
        MXStrongifyAndReturnIfNil(self);
        
        NSError *error;
        
        NSData *privateKey;
        MXSecretStoragePassphrase *passphraseInfo;
        
        if (passphrase)
        {
            // Generate a private key from the passphrase
            NSString *salt;
            NSUInteger iterations;
            privateKey = [MXKeyBackupPassword generatePrivateKeyWithPassword:passphrase
                                                                        salt:&salt
                                                                  iterations:&iterations
                                                                       error:&error];
            if (!error)
            {
                passphraseInfo = [MXSecretStoragePassphrase new];
                passphraseInfo.algorithm = @"m.pbkdf2";
                passphraseInfo.salt = salt;
                passphraseInfo.iterations = iterations;
            }
        }
        else
        {
            OLMPkDecryption *decryption = [OLMPkDecryption new];
            [decryption generateKey:&error];
            privateKey = decryption.privateKey;
        }
        
        if (error)
        {
            dispatch_async(dispatch_get_main_queue(), ^{
                failure(error);
            });
            return;
        }
        
        MXSecretStorageKeyContent *ssssKeyContent = [MXSecretStorageKeyContent new];
        ssssKeyContent.name = keyName;
        ssssKeyContent.algorithm = MXSecretStorageKeyAlgorithm.aesHmacSha2;
        ssssKeyContent.passphrase = passphraseInfo;
        // TODO
        // ssssKeyContent.iv = ...
        // ssssKeyContent.mac =
        
        NSString *accountDataId = [self storageKeyIdForKey:keyId];
        MXHTTPOperation *operation2 = [self setAccountData:ssssKeyContent.JSONDictionary forType:accountDataId success:^{
            
            MXSecretStorageKeyCreationInfo *keyCreationInfo = [MXSecretStorageKeyCreationInfo new];
            keyCreationInfo.keyId = keyId;
            keyCreationInfo.content = ssssKeyContent;
            keyCreationInfo.privateKey = privateKey;
            keyCreationInfo.recoveryKey = [MXRecoveryKey encode:privateKey];
            
            dispatch_async(dispatch_get_main_queue(), ^{
                success(keyCreationInfo);
            });
            
        } failure:^(NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                failure(error);
            });
        }];
        
        [operation mutateTo:operation2];
    });
    
    return operation;
}

- (nullable MXSecretStorageKeyContent *)keyWithKeyId:(NSString*)keyId
{
    MXSecretStorageKeyContent *key;

    NSString *accountDataId = [self storageKeyIdForKey:keyId];
    NSDictionary *keyDict = [self.mxSession.accountData accountDataForEventType:accountDataId];
    if (keyDict)
    {
        MXJSONModelSetMXJSONModel(key, MXSecretStorageKeyContent.class, keyDict);
    }
    
    return key;
}

- (MXHTTPOperation *)setAsDefaultKeyWithKeyId:(NSString*)keyId
                                      success:(void (^)(void))success
                                      failure:(void (^)(NSError *error))failure
{
    return [self.mxSession setAccountData:@{
                                            @"key": keyId
                                            } forType:kMXEventTypeStringSecretStorageDefaultKey
                                  success:success failure:failure];
}

- (nullable NSString *)defaultKeyId
{
    NSString *defaultKeyId;
    NSDictionary *defaultKeyDict = [self.mxSession.accountData accountDataForEventType:kMXEventTypeStringSecretStorageDefaultKey];
    if (defaultKeyDict)
    {
        MXJSONModelSetString(defaultKeyId, defaultKeyDict[@"key"]);
    }
    
    return defaultKeyId;
}

- (nullable MXSecretStorageKeyContent *)defaultKey
{
    MXSecretStorageKeyContent *defaultKey;
    NSString *defaultKeyId = self.defaultKeyId;
    if (defaultKeyId)
    {
        defaultKey = [self keyWithKeyId:defaultKeyId];
    }
    
    return defaultKey;
}


#pragma mark - Secret storage

- (MXHTTPOperation *)storeSecret:(NSString*)secret
                    withSecretId:(nullable NSString*)secretId
           withSecretStorageKeys:(NSDictionary<NSString*, NSData*> *)keys
                         success:(void (^)(void))success
                         failure:(void (^)(NSError *error))failure
{
    failure(nil);
    return nil;
}


- (nullable NSDictionary<NSString*, MXSecretStorageKeyContent*> *)secretStorageKeysUsedForSecretWithSecretId:(NSString*)secretId
{
    NSDictionary *accountData = [_mxSession.accountData accountDataForEventType:secretId];
    if (!accountData)
    {
        NSLog(@"[MXSecretStorage] secretStorageKeysUsedForSecretWithSecretId: ERROR: No Secret for secret id %@", secretId);
        return nil;
    }
    
    NSDictionary *encryptedContent;
    MXJSONModelSetDictionary(encryptedContent, accountData[@"encrypted"]);
    
    NSMutableDictionary *secretStorageKeys = [NSMutableDictionary dictionary];
    for (NSString *keyId in encryptedContent)
    {
        MXSecretStorageKeyContent *key = [self keyWithKeyId:keyId];
        if (key)
        {
            secretStorageKeys[keyId] = key;
        }
    }
    
    return secretStorageKeys;
}

- (void)secretWithSecretId:(NSString*)secretId
    withSecretStorageKeyId:(nullable NSString*)keyId
                privateKey:(NSData*)privateKey
                   success:(void (^)(NSString *secret))success
                   failure:(void (^)(NSError *error))failure
{
    NSDictionary *accountData = [_mxSession.accountData accountDataForEventType:secretId];
    if (!accountData)
    {
        NSLog(@"[MXSecretStorage] secretWithSecretId: ERROR: Unknown secret id %@", secretId);
        failure([self errorWithCode:MXSecretStorageUnknownSecretCode reason:[NSString stringWithFormat:@"Unknown secret %@", secretId]]);
        return;
    }
    
    if (!keyId)
    {
        keyId = self.defaultKeyId;
    }
    if (!keyId)
    {
        NSLog(@"[MXSecretStorage] secretWithSecretId: ERROR: No key id provided and no default key id");
        failure([self errorWithCode:MXSecretStorageUnknownKeyCode reason:@"No key id"]);
        return;
    }
    
    MXSecretStorageKeyContent *key = [self keyWithKeyId:keyId];
    if (!key)
    {
        NSLog(@"[MXSecretStorage] secretWithSecretId: ERROR: No key for with id %@", secretId);
        failure([self errorWithCode:MXSecretStorageUnknownKeyCode reason:[NSString stringWithFormat:@"Unknown key %@", keyId]]);
        return;
    }
    
    NSDictionary *encryptedContent;
    MXJSONModelSetDictionary(encryptedContent, accountData[@"encrypted"]);
    if (!encryptedContent)
    {
        NSLog(@"[MXSecretStorage] secretWithSecretId: ERROR: No encrypted data for the secret");
        failure([self errorWithCode:MXSecretStorageSecretNotEncryptedCode reason:[NSString stringWithFormat:@"Missing content for secret %@", secretId]]);
        return;
    }
    
    MXEncryptedSecretContent *secretContent;
    MXJSONModelSetMXJSONModel(secretContent, MXEncryptedSecretContent.class, encryptedContent[keyId]);
    if (!secretContent)
    {
        NSLog(@"[MXSecretStorage] secretWithSecretId: ERROR: No content for secret %@ with key %@: %@", secretId, keyId, encryptedContent);
        failure([self errorWithCode:MXSecretStorageSecretNotEncryptedWithKeyCode reason:[NSString stringWithFormat:@"Missing content for secret %@ with key %@", secretId, keyId]]);
        return;
    }
    
    if (![key.algorithm isEqualToString:MXSecretStorageKeyAlgorithm.aesHmacSha2])
    {
        NSLog(@"[MXSecretStorage] secretWithSecretId: ERROR: Unsupported algorihthm %@", key.algorithm);
        failure([self errorWithCode:MXSecretStorageUnsupportedAlgorithmCode reason:[NSString stringWithFormat:@"Unknown algorithm %@", key.algorithm]]);
        return;
    }
    
    MXWeakify(self);
    dispatch_async(processingQueue, ^{
        MXStrongifyAndReturnIfNil(self);
        
        NSError *error;
        NSString *secret = [self decryptSecretWithSecretId:secretId secretContent:secretContent withPrivateKey:privateKey error:&error];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error)
            {
                failure(error);
            }
            else
            {
                success(secret);
            }
        });
    });
}


#pragma mark - Private methods -

- (NSString *)storageKeyIdForKey:(NSString*)key
{
    return [NSString stringWithFormat:kSecretStorageKeyIdFormat, key];
}

// Do accountData update on the main thread as expected by MXSession
- (MXHTTPOperation*)setAccountData:(NSDictionary*)data
                           forType:(NSString*)type
                           success:(void (^)(void))success
                           failure:(void (^)(NSError *error))failure
{
    MXHTTPOperation *operation = [MXHTTPOperation new];
    
    MXWeakify(self);
    dispatch_async(dispatch_get_main_queue(), ^{
        MXStrongifyAndReturnIfNil(self);
        
        MXHTTPOperation *operation2 = [self.mxSession setAccountData:data forType:type success:^{
            dispatch_async(self->processingQueue, ^{
                success();
            });
        } failure:^(NSError *error) {
            dispatch_async(self->processingQueue, ^{
                failure(error);
            });
        }];
        
        [operation mutateTo:operation2];
    });
    
    return operation;
}

- (NSError*)errorWithCode:(MXSecretStorageErrorCode)code reason:(NSString*)reason
{
    return [NSError errorWithDomain:MXSecretStorageErrorDomain
                        code:code
                    userInfo:@{
                               NSLocalizedDescriptionKey: [NSString stringWithFormat:@"MXSecretStorage: %@", reason]
                               }];
}


#pragma mark - aes-hmac-sha2

- (nullable NSString *)decryptSecretWithSecretId:(NSString*)secretId
                                   secretContent:(MXEncryptedSecretContent*)secretContent
                                  withPrivateKey:(NSData*)privateKey
                                           error:(NSError**)error
{
    NSMutableData *zeroSalt = [NSMutableData dataWithLength:32];
    [zeroSalt resetBytesInRange:NSMakeRange(0, zeroSalt.length)];
    
    NSData *pseudoRandomKey = [MXHkdfSha256 deriveSecret:privateKey
                                                    salt:zeroSalt
                                                    info:[secretId dataUsingEncoding:NSUTF8StringEncoding]
                                            outputLength:64];
    
    // The first 32 bytes are used as the AES key, and the next 32 bytes are used as the MAC key
    NSData *aesKey = [pseudoRandomKey subdataWithRange:NSMakeRange(0, 32)];
    NSData *hmacKey = [pseudoRandomKey subdataWithRange:NSMakeRange(32, pseudoRandomKey.length - 32)];


    NSData *iv = secretContent.iv ? [MXBase64Tools dataFromUnpaddedBase64:secretContent.iv] : [NSMutableData dataWithLength:16];
    
    NSData *hmac = [MXBase64Tools dataFromUnpaddedBase64:secretContent.mac];
    if (!hmac)
    {
        NSLog(@"[MXSecretStorage] decryptSecret: ERROR: Bad base64 format for MAC: %@", secretContent.mac);
        *error = [self errorWithCode:MXSecretStorageBadMacCode reason:[NSString stringWithFormat:@"Bad base64 format for MAC: %@", secretContent.mac]];
        return nil;
    }

    NSData *cipher = [MXBase64Tools dataFromUnpaddedBase64:secretContent.ciphertext];
    if (!cipher)
    {
        NSLog(@"[MXSecretStorage] decryptSecret: ERROR: Bad base64 format for ciphertext: %@", secretContent.ciphertext);
        *error = [self errorWithCode:MXSecretStorageBadCiphertextCode reason:[NSString stringWithFormat:@"Bad base64 format for ciphertext: %@", secretContent.ciphertext]];
        return nil;
    }
    
    NSData *decrypted = [MXAesHmacSha2 decrypt:cipher
                                        aesKey:aesKey iv:iv
                                       hmacKey:hmacKey hmac:hmac
                                         error:error];
    
    if (*error)
    {
        NSLog(@"[MXSecretStorage] decryptSecret: ERROR: Decryption failes: %@", *error);
        return nil;
    }
    
    return [[NSString alloc] initWithData:decrypted encoding:NSUTF8StringEncoding];
}

@end
