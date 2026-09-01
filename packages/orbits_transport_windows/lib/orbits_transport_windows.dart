import 'package:orbits_transport/orbits_transport.dart';

class OrbitsTransportWindows {
  static void registerWith() {
    OrbitsTransportPlatform.instance = MethodChannelOrbitsTransport();
  }
}
