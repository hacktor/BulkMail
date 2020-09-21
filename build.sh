#!/bin/bash

# assume default cni pod network
CNI_NET=10.88.0.0/16
GATEWAY=10.88.0.1

newcontainer=$(buildah from ubuntu:bionic)

buildah config --created-by "TU Delft ICT-SYS-LIN"  $newcontainer
buildah config --author "Ruben de Groot" --label name=nagiospod $newcontainer
buildah config --env CNI_NET=${CNI_NET} --env GATEWAY=${GATEWAY} $newcontainer
buildah copy $newcontainer ./install.sh /usr/bin/install.sh
buildah copy $newcontainer ./entrypoint.sh /usr/bin/entrypoint.sh
buildah run $newcontainer chmod +x /usr/bin/install.sh /usr/bin/entrypoint.sh
buildah run $newcontainer apt -y install libdancer-perl libhtml-template-perl libtemplate-perl libemail-simple-perl libemail-sender-perl libemail-address-xs-perl
buildah run $newcontainer /usr/bin/install.sh
buildah config --port 3000 $newcontainer
buildah config --entrypoint /usr/bin/entrypoint.sh $newcontainer
buildah commit $newcontainer bulkmail:latest

