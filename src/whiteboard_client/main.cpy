#include <sys/types.h>
#include <sys/socket.h>
#include <netdb.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <iostream>
#include "../build/rmkit.h"
#include "../vendor/json/json.hpp"
#include "../shared/string.h"

#define BUF_SIZE 1024

using json = nlohmann::json

class JSONSocket:
  public:
  int sockfd
  struct addrinfo hints;
  struct addrinfo *result, *rp;
  char buf[BUF_SIZE]
  string leftover
  deque<json> out_queue
  std::mutex out_queue_m
  const char* host
  const char* port
  thread *read_thread

  JSONSocket(const char* host, port):
    sockfd = socket(AF_INET, SOCK_STREAM, 0)
    memset(&hints, 0, sizeof(struct addrinfo));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_DGRAM;
    hints.ai_flags = 0;
    hints.ai_protocol = 0;
    self.host = host
    self.port = port
    self.leftover = ""

    self.read_thread = new thread([=]() {
      s := getaddrinfo(host, port, &hints, &result)
      if s != 0:
        fprintf(stderr, "getaddrinfo: %s\n", gai_strerror(s));
        exit(EXIT_FAILURE);

      self.listen()
    })

  void write(json &j):
      json_dump := j.dump()
      msg_c_str := json_dump.c_str()
      ::write(self.sockfd, msg_c_str, strlen(msg_c_str))
      ::write(self.sockfd, "\n", 1)

  void listen():
    bytes_read := -1
    while true:
      while bytes_read <= 0:
        err := connect(self.sockfd, self.result->ai_addr, self.result->ai_addrlen)
        if err == 0 || errno == EISCONN:
            debug "(re)connected"
            break
        debug "(re)connecting...", err, errno
        sleep(1)
      bytes_read = read(sockfd, buf, BUF_SIZE-1)
      debug "bytes read", bytes_read, buf
      if bytes_read <= 0:
          close(self.sockfd)
          self.sockfd = socket(AF_INET, SOCK_STREAM, 0)
          sleep(1)
          continue
      buf[bytes_read] = 0
      sbuf := string(buf)
      memset(buf, 0, BUF_SIZE)

      msgs := str_utils::split(sbuf, '\n')
      if leftover != "" && msgs.size() > 0:
        msgs[0] = leftover + msgs[0]
        leftover = ""
      if sbuf[sbuf.length()-1] != '\n':
        leftover = msgs.back()
        msgs.pop_back()
      debug "msgs", msgs.size()
      for (i:=0; i!=msgs.size(); ++i):
        try:
            msg_json := json::parse(msgs[i].begin(), msgs[i].end())
            out_queue_m.lock()
            out_queue.push_back(msg_json)
            out_queue_m.unlock()
        catch(...):
            debug "COULDNT PARSE", msgs[i]

      out_queue_m.lock()
      debug "out queue in JSONSocket", self.out_queue.size()
      out_queue_m.unlock()

      ui::TaskQueue::wakeup()


class Note: public ui::Widget:
  public:
  int prevx = -1, prevy = -1
  framebuffer::VirtualFB *vfb
  bool full_redraw
  JSONSocket *socket

  Note(int x, y, w, h, JSONSocket* s): Widget(x, y, w, h):
    vfb = new framebuffer::VirtualFB(self.fb->width, self.fb->height)
    vfb->clear_screen()
    self.full_redraw = true
    self.socket = s
    self.mouse_down = false

  void on_mouse_up(input::SynMotionEvent &ev):
    prevx = prevy = -1

  bool ignore_event(input::SynMotionEvent &ev):
    return input::is_touch_event(ev) != NULL

  void on_mouse_move(input::SynMotionEvent &ev):
    width := 5
    if prevx != -1:
      vfb->draw_line(prevx, prevy, ev.x, ev.y, width, GRAY)
      self.dirty = 1

      json j
      j["prevx"] = prevx
      j["prevy"] = prevy
      j["x"] = ev.x
      j["y"] = ev.y
      j["width"] = width
      j["color"] = BLACK

      self.socket->write(j)

    prevx = ev.x
    prevy = ev.y

  void render():
    if self.full_redraw:
      self.full_redraw = false
      memcpy(self.fb->fbmem, vfb->fbmem, vfb->byte_size)
      return

    dirty_rect := self.vfb->dirty_area
    for int i = dirty_rect.y0; i < dirty_rect.y1; i++:
      memcpy(&fb->fbmem[i*fb->width + dirty_rect.x0], &vfb->fbmem[i*fb->width + dirty_rect.x0],
        (dirty_rect.x1 - dirty_rect.x0) * sizeof(remarkable_color))
    self.fb->dirty_area = vfb->dirty_area
    self.fb->dirty = 1
    framebuffer::reset_dirty(vfb->dirty_area)

class App:
  public:
  Note *note
  JSONSocket *socket

  App():
    demo_scene := ui::make_scene()
    ui::MainLoop::set_scene(demo_scene)

    fb := framebuffer::get()
    fb->clear_screen()
    fb->redraw_screen()
    w, h = fb->get_display_size()

    socket = new JSONSocket("rmkit.dev", "65432")
    note = new Note(0, 0, w, h, socket)
    demo_scene->add(note)

  def handle_key_event(input::SynKeyEvent ev):
    // pressing any button will clear the screen
    debug "CLEARING SCREEN"
    note->vfb->clear_screen()
    ui::MainLoop::fb->clear_screen()

  def handle_server_response():
    socket->out_queue_m.lock()
    for (i:=0; i < socket->out_queue.size(); i++):
      j := socket->out_queue[i]
      debug "DRAWING LINE FROM SERVER", j
      try:
        note->vfb->draw_line(j["prevx"], j["prevy"], j["x"], j["y"], j["width"], j["color"])
        note->dirty = 1
      catch(...):
        debug "COULDN'T PARSE RESPONSE FROM SERVER", j
    socket->out_queue.clear()
    socket->out_queue_m.unlock()

  def run():
    ui::MainLoop::key_event += PLS_DELEGATE(self.handle_key_event)

    while true:
      self.handle_server_response()
      ui::MainLoop::main()
      ui::MainLoop::redraw()
      ui::MainLoop::read_input()

app := App()
int main():
  app.run()
