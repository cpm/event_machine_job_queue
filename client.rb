#!ruby

require 'socket'

d = Marshal.dump(inline: "puts 'Hello World'; 5")

s = TCPSocket.new('localhost', 5555)
s.print("QUEUE #{d.size}\n\n#{d}")
ticket = s.gets
puts ticket.inspect
s.close


sleep 15


while true
  s = TCPSocket.new('localhost', 5555)
  s.print("CHECK #{ticket}\n\n")
  resp = s.gets("\n\n")
  case resp
  when /\AWORKING/
    s.close
    puts "WORKING: Retrying after a quick nap."
    sleep 10
    redo
  when /\ANOTFOUND/
    s.close
    puts "Not found?"
    break
  when /\ADONE (\d+)\n\n/
    serialized_data = s.read($1.to_i)
    s.close
    puts Marshal.load(serialized_data).inspect
    break
  end
end

