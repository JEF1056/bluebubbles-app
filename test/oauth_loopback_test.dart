import 'package:bluebubbles/helpers/ui/oauth_helpers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in/google_sign_in.dart';

void main() {
  group('Android loopback Google OAuth fallback', () {
    test('falls back on canceled (Credential Manager surfaces 28444 SHA-1 error as canceled)', () {
      const canceled = GoogleSignInException(
        code: GoogleSignInExceptionCode.canceled,
        description: 'User canceled',
      );
      expect(shouldFallbackToLoopbackOAuth(canceled), isTrue);
    });

    test('builds valid token auth URI without nonce and with userinfo.profile scope', () {
      final uri = buildLoopbackGoogleOAuthUri(
        clientId: 'test-client.apps.googleusercontent.com',
        port: 8641,
        scopes: const ['https://www.googleapis.com/auth/firebase'],
        state: 'state123',
        forceAccountPicker: true,
      );
      expect(uri.queryParameters['response_type'], 'token');
      expect(uri.queryParameters['redirect_uri'], 'http://localhost:8641/oauth/callback');
      expect(uri.queryParameters.containsKey('nonce'), isFalse);
      expect(uri.queryParameters['prompt'], 'select_account');
      final scopes = uri.queryParameters['scope']!.split(' ');
      expect(scopes, contains('https://www.googleapis.com/auth/firebase'));
      expect(scopes, contains('https://www.googleapis.com/auth/userinfo.profile'));
    });

    test('falls back on client configuration / SHA-1 errors', () {
      const misconfig = GoogleSignInException(
        code: GoogleSignInExceptionCode.clientConfigurationError,
        description: 'Developer error 10',
      );
      expect(shouldFallbackToLoopbackOAuth(misconfig), isTrue);
      expect(shouldFallbackToLoopbackOAuth(Exception('generic')), isTrue);
    });

    test('parses access_token when state matches', () {
      final token = parseLoopbackOAuthCallback(
        'state=abc123&access_token=ya29.test_token&token_type=Bearer',
        'abc123',
      );
      expect(token, 'ya29.test_token');
    });

    test('rejects mismatched state', () {
      expect(
        () => parseLoopbackOAuthCallback('state=wrong&access_token=ya29.test', 'abc123'),
        throwsA(isA<GoogleOAuthException>()),
      );
    });

    test('surfaces OAuth error cleanly', () {
      expect(
        () => parseLoopbackOAuthCallback('error=access_denied&state=abc123', 'abc123'),
        throwsA(isA<GoogleOAuthException>()),
      );
    });
  });
}
