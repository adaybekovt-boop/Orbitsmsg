import 'package:orbits_transport/orbits_transport.dart';

class OrbitsTransportMacos {
  static void registerWith() {
    OrbitsTransportPlatform.instance = MethodChannelOrbitsTransport();
  }
}
