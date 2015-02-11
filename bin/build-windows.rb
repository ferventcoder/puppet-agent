require 'yaml'
require 'json'
require 'fileutils'

# The architecture of cfacter/the installer we are going to build
ARCH                 = ENV['ARCH'] || 'x64'

# The version of this build
AGENT_VERSION_STRING = %x{git describe --tags}.chomp.gsub('-', '.')

# Whether or not we are going to build boost and yaml-cpp or copy them from existing builds
# If `TRUE`, this will build boost and yaml-cpp according to the specifications in
# git://github.com/puppetlabs/cfacter/master/contrib/cfacter.ps1
# If `FALSE`, this will download and unpack prebuilt boost and yaml-cpp arcives.
BUILD_SOURCE         = ENV['BUILD_SOURCE'] || '0'

# Parsed information that we need to specify in order to know where to find different built cfacter bits
# and correctly pass information to the cfacter build script
script_arch          = "#{ARCH =='x64' ? '64' : '32'}"

# The refs we will use when building the MSI
PUPPET       = JSON.parse(File.read('configs/components/puppet.json'))
FACTER       = JSON.parse(File.read('configs/components/facter.json'))
CFACTER      = JSON.parse(File.read('configs/components/cfacter.json'))
HIERA        = JSON.parse(File.read('configs/components/hiera.json'))
MCO          = JSON.parse(File.read('configs/components/mcollective.json'))
WINDOWS      = JSON.parse(File.read('configs/components/windows_puppet.json'))
WINDOWS_RUBY = JSON.parse(File.read('configs/components/windows_ruby.json'))

ssh_key = ENV['VANAGON_SSH_KEY'] ? "-i #{ENV['VANAGON_SSH_KEY']}" : ''



# Retrieve a vm
curl_output=`curl -d --url http://vmpooler.delivery.puppetlabs.net/vm/win-2012-x86_64`
hostname = /\"hostname\": \"(.*)\"/.match(curl_output)[1]

# Set up the environment so I don't keep crying
ssh_env = "export PATH=\'/cygdrive/c/tools/ruby215/bin:/cygdrive/c/ProgramData/chocolatey/bin:/cygdrive/c/Program Files (x86)/Windows Installer XML v3.5/bin:/usr/local/bin:/usr/bin:/cygdrive/c/Windows/system32:/cygdrive/c/Windows:/cygdrive/c/Windows/System32/Wbem:/cygdrive/c/Windows/System32/WindowsPowerShell/v1.0:/bin\'"

result = Kernel.system("ssh #{ssh_key} -tt -o StrictHostKeyChecking=no Administrator@#{hostname} \"echo \\\"#{ssh_env}\\\" >> ~/.bash_profile\"")
fail "Unable to connect to the host. Is is possible that you aren't on VPN or connected to the internal PL network?" unless result


### Build CFacter
#
#

Kernel.system("ssh #{ssh_key} -tt -o StrictHostKeyChecking=no Administrator@#{hostname} 'source .bash_profile ; echo $PATH'")

# Download and execute the cfacter build script
# this script lives in the puppetlabs/cfacter repo
result = Kernel.system("ssh #{ssh_key} -tt -o StrictHostKeyChecking=no Administrator@#{hostname} \"curl -O #{CFACTER['url'].sub('git://github.com','https://raw.githubusercontent.com')}/#{CFACTER['ref'].sub('origin/','')}/contrib/cfacter.ps1 && powershell.exe -NoProfile -ExecutionPolicy Unrestricted -InputFormat None -Command ./cfacter.ps1 -arch #{script_arch} -buildSource #{BUILD_SOURCE}\"")
fail "It looks like the cfacter build script failed for some reason. I would suggest ssh'ing into the box and poking around" unless result

# Move all necessary dll's into cfacter bindir
Kernel.system("ssh #{ssh_key} -tt -o StrictHostKeyChecking=no Administrator@#{hostname} \"cp /cygdrive/c/tools/mingw#{script_arch}/bin/libgcc_s_#{ARCH == 'x64' ? 'seh' : 'sjlj'}-1.dll /cygdrive/c/tools/mingw#{script_arch}/bin/libstdc++-6.dll /cygdrive/c/tools/mingw#{script_arch}/bin/libwinpthread-1.dll /home/Administrator/cfacter/release/bin/\"")

# Zip up the built archives
Kernel.system("ssh #{ssh_key} -tt -o StrictHostKeyChecking=no Administrator@#{hostname} \"source .bash_profile ; 7za.exe a -r -tzip -x\!*obj cfacter.zip 'C:\\cygwin64\\home\\Administrator\\cfacter\\release\\bin' 'C:\\cygwin64\\home\\Administrator\\cfacter\\lib\\inc' 'C:\\cygwin64\\home\\Administrator\\cfacter\\release\\lib\\cfacter.rb'\"")


### Build puppet-agent.msi


CONFIG = {
  :repos => {
    'puppet' => {
      :ref  => PUPPET['ref'],
      :repo => PUPPET['url']
    },
    'hiera' => {
      :ref  => HIERA['ref'],
      :repo => HIERA['url']
    },
    'facter' => {
      :ref  => FACTER['ref'],
      :repo => FACTER['url']
    },
    'mcollective' => {
      :ref  => MCO['ref'],
      :repo => MCO['url']
    },
    'cfacter' => {
      :archive => 'cfacter.zip',
      :path    => 'file:///home/Administrator'
    },
    'sys' => {
      :ref  => WINDOWS_RUBY['ref'][ARCH],
      :repo => WINDOWS_RUBY['url']
    },
  }
}
File.open("winconfig.yaml", 'w') { |f| f.write(YAML.dump(CONFIG)) }

# Install Wix35 with chocolatey
Kernel.system("ssh #{ssh_key} -tt -o StrictHostKeyChecking=no Administrator@#{hostname} \"source .bash_profile ; choco install -y Wix35\"")

# Clone puppet_for_the_win
result = Kernel.system("ssh #{ssh_key} -tt -o StrictHostKeyChecking=no Administrator@#{hostname} \"source .bash_profile ; git clone #{WINDOWS['url']} ; cd puppet_for_the_win && git checkout #{WINDOWS['ref']}\"")
fail "It seems there were some issues cloning the puppet_for_the_win repo" unless result

# Send the config file over so we know what to build with
Kernel.system("scp #{ssh_key} winconfig.yaml Administrator@#{hostname}:/home/Administrator/puppet_for_the_win/")

# Build the MSI with automation in puppet_for_the_win
result = Kernel.system("ssh #{ssh_key} -tt -o StrictHostKeyChecking=no Administrator@#{hostname} \"source .bash_profile ; cd /home/Administrator/puppet_for_the_win ; AGENT_VERSION_STRING=#{AGENT_VERSION_STRING} ARCH=#{ARCH} c:/tools/ruby215/bin/rake clobber windows:build config=winconfig.yaml\"")
fail "It seems there were some issues building the puppet-agent msi" unless result

# Fetch back the built installer
FileUtils.mkdir_p("output/windows/#{ARCH}")
Kernel.system("scp #{ssh_key} Administrator@#{hostname}:/home/Administrator/puppet_for_the_win/pkg/puppet-agent-#{AGENT_VERSION_STRING}-#{ARCH}.msi output/windows/#{ARCH}/")


# delete a vm only if we successfully brought back the msi
if File.exists?("output/windows/#{ARCH}/puppet-agent-#{AGENT_VERSION_STRING}-#{ARCH}.msi")
  Kernel.system("curl -X DELETE --url \"http://vmpooler.delivery.puppetlabs.net/vm/#{hostname}\"")
  FileUtils.rm 'winconfig.yaml'
end