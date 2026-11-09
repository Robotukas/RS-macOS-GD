// Bridging header for the Xcode app target: the shared C translator (Shared/GDHubXlate.c). SwiftPM builds get the same
// symbols through the GDHubXlate module (Shared/module.modulemap); Swift files say `#if canImport(GDHubXlate)`.
#include "GDHubXlate.h"
