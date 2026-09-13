#pragma once
#include <Arduino.h>
#define WL_CONNECTED 3
struct WiFiStub { int status() { return WL_CONNECTED; } };
inline WiFiStub WiFi;
