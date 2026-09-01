import 'package:orbits_transport/orbits_transport.dart';

class OrbitsTransportAndroid {
  static void registerWith() {
    OrbitsTransportPlatform.instance = MethodChannelOrbitsTransport();
  }
}
