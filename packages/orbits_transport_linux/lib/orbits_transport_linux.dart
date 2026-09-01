import 'package:orbits_transport/orbits_transport.dart';

class OrbitsTransportLinux {
  static void registerWith() {
    OrbitsTransportPlatform.instance = MethodChannelOrbitsTransport();
  }
}
