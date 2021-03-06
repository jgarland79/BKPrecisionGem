#!/usr/bin/env ruby

$:.push File.join(File.dirname(__FILE__), 'lib')

require 'bkp'
require 'time'
require 'collectd'
require 'pp'

#/dev/serial/by-id/usb-Arachnid_Labs_Ltd_Re\:load_Pro_DAXWOWW3-if00-port0

@dcload = BKP::M8500.new({
      :port_str => "/dev/serial/by-id/usb-Prolific_Technology_Inc._USB-Serial_Controller-if00-port0",
      :baud_rate => 4800,
      :data_bits => 8,
      :stop_bits => 1,
      :parity => SerialPort::NONE})

@power = BKP::M1900B.new({
      :port_str => "/dev/serial/by-id/usb-Silicon_Labs_CP2102_USB_to_UART_Bridge_Controller_0001-if00-port0",
      :baud_rate => 9600,
      :data_bits => 8,
      :stop_bits => 1,
      :parity => SerialPort::NONE})

@dmm = BKP::M2831E.new({
      :port_str => "/dev/serial/by-id/usb-Silicon_Labs_2831E_Multimeter_0001-if00-port0",
      :baud_rate => 9600,
      :data_bits => 8,
      :stop_bits => 1,
      :parity => SerialPort::NONE})

Collectd.add_server(10, '192.168.1.100', 25826)

Stats = Collectd.lab(:battery)

@state = Hash.new
@state[:charging] = Hash.new
@state[:charging][:state] = false
@state[:charging][:start_time] = Time.now

@state[:battery] = Hash.new
@state[:battery][:charged] = false

@state[:float] = Hash.new
@state[:float][:state] = false
@state[:float][:start_time] = Time.now
@state[:discharging] = Hash.new
@state[:discharging][:state] = false
@state[:discharging][:start_time] = Time.now


def bin_to_hex(s)
  s.each.map { |b| '0x' + b.to_s(16) }.join(' ')
end

def charge(volts, amps)

  #disable the load
  pp @dcload.Remote(true)
  pp @dcload.LoadEnable(false)
  pp @dcload.Remote(false)

  sleep 1

  puts @power.volt(volts)
  puts @power.curr(amps)

  #turn power on
  puts @power.sout(true)

  @state[:charging][:state] = true
  @state[:charging][:start_time] = Time.now
  @state[:float][:state] = false
  @state[:discharging][:state] = false

end

def discharge(amps)
  #turn off the power supply
  puts @power.sout(false)

  sleep 1

  pp @dcload.Remote(true)
  pp @dcload.LoadEnable(false)
  pp @dcload.SetMode("\x00")
  pp @dcload.SetCurrent(amps)
  pp @dcload.SetMode("\x04")
  pp @dcload.SetBatMin(0.899)
  pp @dcload.LoadEnable(true)
  pp @dcload.Remote(false)


  @state[:charging][:state] = false
  @state[:float][:state] = false
  @state[:discharging][:state] = true
  @state[:discharging][:start_time] = Time.now
end

def float()
  #turn off the power supply
  puts @power.sout(false)

  #turn off the load
  pp @dcload.Remote(true)
  pp @dcload.LoadEnable(false)
  pp @dcload.Remote(false)

  @state[:charging][:state] = false
  @state[:float][:state] = true
  @state[:float][:start_time] = Time.now
  @state[:discharging][:state] = false

end


#pp @dcload.Remote(true)
#pp @dcload.SetCurrent(15)
#pp @dcload.GetCurrent

#pp @dcload.ReadDisplay
#pp lo@dcloadad.LoadEnable(false)
#pp @dcload.LoadEnable(false)
#pp @dcload.Remote(false)


#puts power.volt(3)
#puts power.curr(30)

#turn power on/off
#puts power.sout(false)

#limts
#puts sovp(32)
#puts socp(30)

#puts "gets = ", gets()
#puts "getd = ", getd()
#puts "govp = ", govp()
#puts "gocp = ", gocp()
#puts "gmax = ", gmax()
#puts runm(1)

discharge_amps = 30

#charge(2.5, 30)
#discharge(discharge_amps)

#float()

puts @dmm.idn()

file = File.open("data.#{Process.pid}.csv", "w")

max_volts = 0

min_volts = 1000

peak_delta = 0

while true
  time = Time.now
  power_volts, power_current, power_status = @power.getd
  set_volts, set_current = @power.gets
  dmm_volts = @dmm.fetch
  load_data = @dcload.ReadDisplay
  #puts load_data
  Stats.voltage(:load).gauge = load_data[:voltage]
  Stats.current(:load).gauge = load_data[:current]
  Stats.power(:load).gauge = load_data[:power]
  Stats.voltage(:dmm).gauge = dmm_volts
  Stats.current(:power).gauge = power_current
  Stats.voltage(:power).gauge = power_volts
  Stats.current(:power_set).gauge = set_current
  Stats.voltage(:power_set).gauge = set_volts

  max_volts = dmm_volts if dmm_volts > max_volts
  min_volts = dmm_volts if dmm_volts < min_volts

  drop = (max_volts - dmm_volts).round(4) if dmm_volts <= max_volts

  rise = (dmm_volts - min_volts).round(4) if min_volts <= dmm_volts

  Stats.voltage(:dmm_drop).gauge = drop

  Stats.voltage(:dmm_rise).gauge = rise


  Stats.voltage(:dmm_max).gauge = max_volts
  Stats.voltage(:dmm_min).gauge = min_volts

  text = "#{time.utc.iso8601(3)}, #{dmm_volts}, #{drop}, #{rise}, #{max_volts}, #{min_volts}, #{power_volts}, #{power_current}, #{power_status}, #{set_current}, #{set_volts}, #{load_data[:voltage]}, #{load_data[:current]}, #{load_data[:power]}\n"
  puts text
  file.write(text)
  file.flush

  if power_volts >= (dmm_volts + 0.1) && load_data[:current] == 0
    @state[:charging][:state] = true
  else
    @state[:charging][:state] = false
  end

  if @state[:charging][:state] == false && power_volts <= dmm_volts && load_data[:current] > 0
    @state[:discharging][:state] = true
  else
    @state[:discharging][:state] = false
  end

  if @state[:discharging][:state] == false && @state[:charging][:state] == false
    @state[:float][:state] = true
  end

  if @state[:discharging][:state] == true || @state[:charging][:state] == true
    @state[:float][:state] = false
  end

  pp @state

  if @state[:charging][:state] == true && power_volts >= (dmm_volts + 0.1) && drop >= 0.0003 && dmm_volts >= 1.7
    @state[:battery][:charged] = true
    float()
    max_volts = 0
    min_volts = 1000
  end

  if @state[:battery][:charged] == false && @state[:float][:state] == true && dmm_volts >= 1.3 && dmm_volts <= 1.4
    charge(2.5, 30)
    max_volts = 0
    min_volts = 1000
  end

  if @state[:battery][:charged] == true && @state[:float][:state] == true && dmm_volts <= 1.47 # && drop >= 0.2
    @state[:battery][:charged] = false
    discharge(discharge_amps)
    max_volts = 0
    min_volts = 1000
  end

  delay = ( 1 - (Time.now - time))
  sleep delay if delay > 0

end


#exit unless dmm.cmd("*IDN?").split("\s")[0] == "2831E"
#exit unless dmm.cmd(":FUNCtion?") == "volt:dc"

#puts dmm.cmd(":VOLTage:DC:RANGe:AUTO?").to_i

#puts dmm.cmd(":FUNCtion?")

#puts dmm.cmd(":DISPlay:ENABle?").to_i
