import 'package:orbits_transport/orbits_transport.dart';

class OrbitsTransportIos {
  static void registerWith() {
    OrbitsTransportPlatform.instance = MethodChannelOrbitsTransport();
  }
}
