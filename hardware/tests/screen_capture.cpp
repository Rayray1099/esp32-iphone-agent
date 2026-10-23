#include "../hid_bridge/src/clicker/screen.h"
#include <array>
#include <fstream>
#include <filesystem>
#include <cassert>
int main(int argc,char** argv){
  std::filesystem::path folder=argc>1?argv[1]:"output/screens";std::filesystem::create_directories(folder);
  std::array<uint16_t,320*240> pixels{};clicker::ScreenData d;d.profile="FAST REPEAT 150";d.network="AP + EDUROAM";d.ip="192.168.4.1";d.usb="OK";
  d.ble="CONNECTED";d.vpn="100.82.93.22";d.ssid="ESP32Agent-DEMO";d.password="DEMO-ONLY";d.token="DEMO TOKEN - NOT A REAL CREDENTIAL";d.ota="VERIFYING 75 PERCENT";
  d.clicks=123456;d.loops=42;d.late=3;d.heap=112344;d.psram=6041120;d.uptime=3600;d.schedules=16;d.point=999;d.cps=149.8;d.running=true;
  d.qr="WIFI:T:WPA;S:ESP32Agent-DEMO;P:DEMO-ONLY;;";d.requestedCps=150;d.rssi=-51;d.reset="POWER-ON";
  d.animationMs=1280; for(int i=0;i<24;++i)d.history[i]=135+(i%7)*2;
  d.target="IPHONE / A1:B2";d.controllers=1;d.inputConnected=true;d.output="BT";
  assert(std::strcmp(d.runState(),"CLICKING")==0);
  assert(d.stateColor()==0x6ff3);
  for(int page=0;page<14;++page){
    if(page==4){d.running=false;d.error="EAP CERTIFICATE MISMATCH";}
    if(page==5){d.ota="INVALID SIGNATURE";}
    if(page==6){d.running=false;assert(std::strcmp(d.runState(),"STOPPED")==0);assert(d.stateColor()==0xfdc6);}
    if(page==7){d.inputConnected=false;d.target="NO TARGET";assert(std::strcmp(d.runState(),"NO TARGET")==0);assert(d.stateColor()==0xfa6b);}
    if(page==8){d.releasing=true;assert(std::strcmp(d.runState(),"STOPPING")==0);assert(d.stateColor()==0xfc6e);}
    if(page>=9) {
      d.target="IPHONE / A1:B2";
      d.agent.update("100 thinking 7 40 440 3800 210 84 Choose_action", 100);
      if(page==10) d.agent.update("100 acting 8 40 440 3800 210 85 Tap", 200);
      if(page==11) d.agent.update("100 done 8 40 440 3800 210 87 Completed", 300);
      if(page==12) d.agent.update("101 failed 8 40 440 3800 210 87 Run_error", 300);
      d.animationMs=page==13?10000:500;
    }
    clicker::Screen(pixels.data()).render(page>=9?4:page<4?page:page==4?2:page==5?3:0,d);
    char name[32];snprintf(name,sizeof name,"tft-%d.ppm",page);auto file=folder/name;std::ofstream out(file,std::ios::binary);out<<"P6\n320 240\n255\n";
    for(auto color:pixels){char rgb[]={char(((color>>11)&31)*255/31),char(((color>>5)&63)*255/63),char((color&31)*255/31)};out.write(rgb,3);}
  }
}
