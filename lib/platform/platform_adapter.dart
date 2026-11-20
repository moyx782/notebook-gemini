export 'platform_adapter_stub.dart'
    if (dart.library.io) 'platform_adapter_io.dart'
    if (dart.library.js_interop) 'platform_adapter_web.dart';
