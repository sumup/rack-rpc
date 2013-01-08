#!/bin/bash
gem uninstall sumup-rack-rpc
rm -rf ./sumup-rack-rpc-*.gem
gem build sumup-rack-rpc.gemspec
gem install sumup-rack-rpc --local ./sumup-rack-rpc-*.gem --no-ri --no-rdoc