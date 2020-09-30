#!/bin/bash

# assume default cni pod network
CNI_NET=10.88.0.0/16
GATEWAY=10.88.0.1

newcontainer=$(buildah from ubuntu:focal)

buildah config --created-by "TU Delft ICT-SYS-LIN"  $newcontainer
buildah config --author "Ruben de Groot" --label name=nagiospod $newcontainer
buildah config --env CNI_NET=${CNI_NET} --env GATEWAY=${GATEWAY} $newcontainer
buildah run $newcontainer apt update
buildah run $newcontainer apt -y install libdancer-perl libhtml-template-perl libtemplate-perl libemail-simple-perl libemail-sender-perl libemail-address-xs-perl libnet-imap-client-perl libdbd-sqlite3-perl
buildah copy $newcontainer bin /root/bin
buildah copy $newcontainer config.yml /root/
buildah copy $newcontainer environments /root/environments
buildah copy $newcontainer lib /root/lib
buildah copy $newcontainer public /root/public
buildah copy $newcontainer views /root/views
buildah config --port 3000 $newcontainer
buildah config --cmd "cd /root/; ./bin/app.pl" $newcontainer
buildah commit $newcontainer bulkmail:latest

