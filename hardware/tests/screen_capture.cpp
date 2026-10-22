#include "../hid_bridge/src/clicker/screen.h"
#include <array>
#include <fstream>
#include <filesystem>
int main(int argc,char** argv){
  std::filesystem::path folder=argc>1?argv[1]:"output/screens";std::filesystem::create_directories(folder);
  std::array<uint16_t,320*240> pixels{};clicker::ScreenData d;d.profile="FAST REPEAT 150";d.network="AP + EDUROAM";d.ip="192.168.4.1";d.usb="OK";
  d.ble="CONNECTED";d.vpn="100.82.93.22";d.ssid="ESP32Agent-DEMO";d.password="DEMO-ONLY";d.token="DEMO TOKEN - NOT A REAL CREDENTIAL";d.ota="VERIFYING 75 PERCENT";
  d.clicks=123456;d.loops=42;d.late=3;d.heap=112344;d.psram=6041120;d.uptime=3600;d.schedules=16;d.point=999;d.cps=149.8;d.running=true;
  d.qr="WIFI:T:WPA;S:ESP32Agent-DEMO;P:DEMO-ONLY;;";d.requestedCps=150;d.rssi=-51;d.reset="POWER-ON";
  for(int page=0;page<6;++page){
    if(page==4){d.running=false;d.error="EAP CERTIFICATE MISMATCH";}
    if(page==5){d.ota="INVALID SIGNATURE";}
    clicker::Screen(pixels.data()).render(page<4?page:page==4?2:3,d);
    char name[32];snprintf(name,sizeof name,"tft-%d.ppm",page);auto file=folder/name;std::ofstream out(file,std::ios::binary);out<<"P6\n320 240\n255\n";
    for(auto color:pixels){char rgb[]={char(((color>>11)&31)*255/31),char(((color>>5)&63)*255/63),char((color&31)*255/31)};out.write(rgb,3);}
  }
}
