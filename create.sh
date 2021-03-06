#! /bin/bash
# -*- coding: utf-8 -*-

# Copyright (C) 2017 Nippon Telegraph and Telephone Corporation.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
# implied.
# See the License for the specific language governing permissions and
# limitations under the License.

. ./create.ini

set_proxy() {
    if [ "${PROXY}"x != ""x ]; then
        PIP_PROXY="--proxy=${PROXY}"
        APT_PROXY="--env http_proxy=${PROXY}"
        HTTP_PROXY="http_proxy=${PROXY} https_proxy=${PROXY}"
        export http_proxy=${PROXY}
        export https_proxy=${PROXY}

        echo "--- Proxy settings ---"
        echo "PIP_PROXY=${PIP_PROXY}"
        echo "APT_PROXY=${APT_PROXY}"
        echo "HTTP_PROXY=${HTTP_PROXY}"
    fi
}

#
# python virtualenv
#
make_virtenv() {
    if [ -d ${VIRTUALENV} ]; then
        echo "${VIRTUALENV} already exist."
    else
        virtualenv ${VIRTUALENV}
    fi
}

#
# install deb packages
#
apt_install() {
    sudo ${HTTP_PROXY} apt -y install ${APT_PKGS} || { echo "apt_install error."; exit 1; }
    sudo apt -y autoremove
}

#
# install python packages
#
pip_install() {
    pip install -U ${PIP_PROXY} ${PIP_PKGS} || { echo "pip_install error."; exit 1; }
}

#
# install go-lang
#
golang_install() {
    local GO_FILE=go${GO_VER}.linux-amd64.tar.gz

    echo "Downloading ${GO_URL}/${GO_FILE}"
    wget -nc -P /tmp ${GO_URL}/${GO_FILE} || { echo "golang_install/wget error."; exit 1; }

    echo "Extracting /tmp/${GO_FILE}"
    sudo tar xf /tmp/${GO_FILE} -C /usr/local || { echo "golang_install/tar error."; exit 1; }
}

#
# install protobuf
#
protoc_install() {
    local PROTOC_FILE=protoc-${PROTOC_VER}-linux-x86_64.zip

    echo "Downloading ${PROTOC_URL}/${PROTOC_FILE}"
    wget -nc -P /tmp ${PROTOC_URL}/${PROTOC_FILE} || { echo "protoc_install/wget error."; exit 1; }

    echo "Extracting /tmp/${PROTOC_FILE}"
    sudo unzip -o -d /usr/local/go /tmp/${PROTOC_FILE} || { echo "protoc_install/unzip error."; exit 1; }

    sudo chmod +x /usr/local/go/bin/protoc
}

#
# install go packages
#
gopkg_install() {
    for PKG in ${GO_PKGS}; do
        echo "go get ${PKG}"
        go get --tags=frr -u ${PKG} || { echo "gopkg_install error."; exit 1; }
    done
}

#
# patch for netlink
#
netlink_patch() {
    cp ./etc/netlink/netlink_gonla.patch /tmp/

    pushd ~/go/src/github.com/vishvananda/netlink/
    patch -p1 < /tmp/netlink_gonla.patch
    go install || { echo "netlink_patch/install error."; exit 1; }
    popd
}

#
# patch for gobgp
#
gobgp_patch() {
    cp ./etc/gobgp/gobgp_for_frr.patch /tmp/

    pushd ~/go/src/github.com/osrg/gobgp
    patch -p1 < /tmp/gobgp_for_frr.patch
    go install --tags=frr ./... || { echo "gobgp_patch/install error."; exit 1; }
    popd
}

#
# Ryu ofdpa patch
#
ryu_patch() {
    cp ./etc/ryu/ryu_ofdpa2.patch /tmp/

    pushd ${VIRTUALENV}/lib/python2.7/site-packages
    patch -b -p1 < /tmp/ryu_ofdpa2.patch
    popd
}

#
# frr deb package
#
frr_pkg() {
    local FRR_DIR=${LXD_WORK_DIR}/frr

    if [ -e $FRR_DIR ]; then
        pushd $FRR_DIR
    else
        git clone $FRR_URL $FRR_DIR || { echo "frr_pkg/clone error."; exit 1; }
        cp etc/frr/frr.patch /tmp/

        pushd $FRR_DIR
        git checkout -b 3.0 origin/stable/3.0
        patch -p1 < /tmp/frr.patch
        ln -s debianpkg debian
    fi

    ./bootstrap.sh
    ./configure
    make dist
    fakeroot debian/rules backports

    cd ${LXD_WORK_DIR}
    tar xvf ${FRR_DIR}/${FRR_ORG}
    cd frr-*
    . /etc/os-release
    tar xvf ${FRR_DIR}/frr_*${ID}${VERSION_ID}*.debian.tar.xz

    fakeroot ./debian/rules binary

    popd
}

#
# lxdbr0 setting
#
lxd_network() {
    local CONF_FILE=/etc/default/lxd-bridge

    sudo sed -i "s/^LXD_IPV4_ADDR=.*/LXD_IPV4_ADDR=\"${LXD_MNG_ADDR}\"/" ${CONF_FILE}
    sudo sed -i "s/^LXD_IPV4_NETMASK=.*/LXD_IPV4_NETMASK=\"${LXD_NETWORK_MASK}\"/" ${CONF_FILE}
    sudo sed -i "s/^LXD_IPV4_NETWORK=.*/LXD_IPV4_NETWORK=\"${LXD_NETWORK_HOST}\"/" ${CONF_FILE}
    sudo sed -i "s/^LXD_IPV4_DHCP_RANGE=.*/LXD_IPV4_DHCP_RANGE=\"${LXD_NETWORK_DHCP_RANGE}\"/" ${CONF_FILE}
    sudo sed -i "s/^LXD_IPV4_DHCP_MAX=.*/LXD_IPV4_DHCP_MAX=\"${LXD_NETWORK_DHCP_MAX}\"/" ${CONF_FILE}
    echo "${CONF_FILE} updated."

    sudo systemctl enable lxd-bridge.service
    echo "lxd-bridge.service enabled."

    sudo systemctl restart lxd-bridge.service
    echo "lxd-bridge.service restarted."
}

#
# ubuntu image
#
lxd_image() {

    pushd ${LXD_WORK_DIR}

    for IMG in ${LXD_IMAGE_LIST}; do
        wget -nc "${LXD_IMAGE_URL}/${IMG}" || { echo "lxd_image/download error."; exit 1; }
    done

    lxc image import ${LXD_IMAGE_LIST} --alias ${LXD_IMAGE_BARE} || echo "${LXD_IMAGE_BARE} maybe exist."
    popd

    lxc image info ${LXD_IMAGE_BARE}

    echo "done"
}

#
# base image
#
lxd_base() {
    local LXD_IMAGE_TEMP="temp"

    if [ ! -e ${LXD_WORK_DIR}/${FRR_PKG} ]; then
        echo "${LXD_WORK_DIR}/${FRR_PKG} not exist!!"
        exit -1
    fi

    lxc launch ${LXD_IMAGE_BARE} ${LXD_IMAGE_TEMP}
    sleep 3

    sudo iptables -t nat -A POSTROUTING -s ${LXD_NETWORK} -o ${BELUG_MNG_IFACE} -j MASQUERADE
    lxc exec ${LXD_IMAGE_TEMP} dhclient -- ${LXD_MNG_IFACE}

    echo "Installing packages"
    lxc exec ${LXD_IMAGE_TEMP} apt ${APT_PROXY} -- -y update || { echo "lxd_base/update error."; exit 1; }
    lxc exec ${LXD_IMAGE_TEMP} apt ${APT_PROXY} -- -y dist-upgrade || { echo "lxd_base upgrade error"; exit 1; }
    lxc exec ${LXD_IMAGE_TEMP} apt ${APT_PROXY} -- -y install ${LXD_APT_PKGS} || { echo "lxd_base/install error."; exit 1; }
    lxc exec ${LXD_IMAGE_TEMP} apt ${APT_PROXY} -- -y autoremomve

    echo "Push ${FRR_PKG} to ${LXD_IMAGE_TEMP}"
    lxc file push ${LXD_WORK_DIR}/${FRR_PKG} ${LXD_IMAGE_TEMP}/tmp/

    echo "Installing ${FRR_PKG} ..."
    lxc exec ${LXD_IMAGE_TEMP} dpkg -- -i /tmp/${FRR_PKG} || { echo "lxd_base/dpkg error."; exit 1; }

    echo "Stopping container ${LXD_IMAGE_TEMP} ..."
    lxc stop ${LXD_IMAGE_TEMP}

    echo "Publishing container ${LXD_IMAGE_TEMP} as ${LXD_IMAGE_BASE} ..."
    lxc publish ${LXD_IMAGE_TEMP} --alias ${LXD_IMAGE_BASE} || { echo "lxd_base/publish error."; exit 1; }

    echo "Deleting container ${LXD_IMAGE_TEMP} ..."
    lxc delete -f ${LXD_IMAGE_TEMP}

    lxc image info ${LXD_IMAGE_BASE}

    echo "done"
}

init_lxd() {
    lxd_network
    lxd_image
    lxd_base
}

init_sys() {
    sudo cp -v etc/modules/modules.conf  /etc/modules-load.d/beluganos.conf
    sudo cp -v etc/modules/modprobe.conf /etc/modprobe.d/beluganos.conf
    sudo modprobe -a belbonding mpls_router mpls_iptunnel
    sudo /etc/init.d/networking restart
}

init_host() {
    sudo useradd -s /sbin/nologin -r ${BELUG_USER}
    sudo mkdir -v -p ${BELUG_HOME}
    sudo mkdir -v -p ${BELUG_DIR}

    local IFACE_TEMP=/tmp/interfaces_temp
    cat >  ${IFACE_TEMP} <<EOF
# -*- coding: utf-8 -*-
auto ${BELUG_OFC_IFACE}
iface ${BELUG_OFC_IFACE} inet static
address ${BELUG_OFC_ADDR}
netmask ${BELUG_OFC_MASK}
EOF
    sudo cp ${IFACE_TEMP} /etc/network/interfaces.d/10-beluganos

    init_sys
}

init_ovs() {
    local BRIDGE=$1
    local OFCADDR=$2
    local DPID=$3

    sudo ovs-vsctl add-br ${BRIDGE}
    sudo ovs-vsctl set-controller ${BRIDGE} tcp:${OFCADDR}
    if [ "$DPID"x != ""x ]; then
        sudo ovs-vsctl set bridge ${BRIDGE} other-config:datapath-id=${DPID}
    fi
    sudo ovs-vsctl show
    sudo ovs-ofctl show ${BRIDGE}
}

beluganos_install() {
    ./bootstrap.sh
    make release
}

confirm() {
    MSG=$1

    echo "$MSG [y/N]"
    read ans
    case $ans in
        [yY]) return 0;;
        *) return 1;;
    esac
}

do_all() {
    confirm "Install ALL" || exit 1

    # install packages and tool
    apt_install
    golang_install
    protoc_install

    # create virtual env
    make_virtenv

    # enable virtual-env and go-env
    . ./setenv.sh

    # install packages
    pip_install
    gopkg_install
    netlink_patch
    gobgp_patch
    ryu_patch

    # create frr deb package
    frr_pkg

    # initailize systems
    init_lxd
    init_host
    init_ovs ${BELUG_OVS_BRIDGE} 127.0.0.1

    beluganos_install
}

do_minimal() {
    confirm "Install minimal" || exit 1

    sudo ${HTTP_PROXY} apt -y install ${APT_MINS}
    make_virtenv
    . ./setenv.sh
    pip install -U ${PIP_PROXY} ansible
    init_lxd
    init_sys
    init_ovs ${SAMPLE_OVS_BRIDGE} ${BELUG_OFC_ADDR} ${SAMPLE_OVS_DPID}
}

do_usage() {
    echo "Usage $0 [OPTIONS]"
    echo "Options:"
    echo "  ''    : run all"
    echo "  pkg   : update apt-packages and re-install golang and protoc"
    echo "  pip   : update pip-packages"
    echo "  gopkg : update go-packages"
    echo "  min   : minimal install for frr container."
    echo "  help  : show this message"
}

set_proxy
case $1 in
    pkg)
        apt_install
        golang_install
        protoc_install
        ;;
    pip)
        . ./setenv.sh
        pip_install
        ryu_patch
        ;;
    gopkg)
        gopkg_install
        netlink_patch
        gobgp_patch
        ;;
    min)
        do_minimal
        ;;
    help)
        do_usage
        ;;
    *)
        do_all
        ;;
esac
