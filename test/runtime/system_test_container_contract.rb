require "fileutils"

abort "Browser-test Rails services must run as UID 1000" unless Process.uid == 1000

source_probe = File.join(__dir__, ".source-write-probe")

begin
  File.write(source_probe, "source mounts must be read-only")
  FileUtils.rm_f(source_probe)
  abort "Browser-test source mount is writable"
rescue Errno::EROFS, Errno::EACCES
  # Expected for the read-only source bind, including foreign-owned checkouts.
end

ARGV.each do |path|
  probe = File.join(path, ".uid-1000-write-probe")
  FileUtils.mkdir_p(path)
  File.write(probe, "ok")
  FileUtils.rm_f(probe)
end

puts "UID 1000 can write every declared runtime path while the source remains read-only"
