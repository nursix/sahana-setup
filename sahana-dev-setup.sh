#!/bin/bash
#
# Script to set up a basic local Sahana Eden instance for development under Linux
#
# Copyright (c) 2016 Dominic König
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
#
# Execute like:
#     bash sahana-dev-setup.sh
#
# =============================================================================
# Use web2py-2.14.6-stable
WEB2PY_COMMIT=cda35fd

if [ $# -eq 1 ]; then
    SAHANAHOME=$1
else
    SAHANAHOME=~/sahana
fi

# Create SAHANAHOME directory
if [ ! -d $SAHANAHOME ]; then
   mkdir -p $SAHANAHOME
else
   echo "Error: directory $SAHANAHOME already exists!"
   echo "Remove it, or specify a non-existent target directory:"
   echo ""
   echo "    sahana-setup [directory]"
   echo ""
   exit 1
fi

# Clone web2py
cd $SAHANAHOME
git clone --recursive git://github.com/web2py/web2py.git

# Reset to release (if specified at the top of this script)
if [ ! -z "$WEB2PY_COMMIT" ]; then
   cd web2py
   git checkout $WEB2PY_COMMIT
   git submodule update
   cd ..
fi

# Clone Sahana
cd $SAHANAHOME
git clone git://github.com/sahana/eden.git

# Create additional subdirectories
cd $SAHANAHOME/eden
declare -a edendirs=("cache" "cron" "databases" "models" "errors" "sessions" "uploads")
for i in "${edendirs[@]}"
do
    if [ ! -d "$i" ]; then
        mkdir -p $i
    fi
done

# Create symbolic link to application
cd $SAHANAHOME/web2py/applications
ln -s $SAHANAHOME/eden eden

# Copy and edit 000_config.py
CONFIG=$SAHANAHOME/eden/models/000_config.py
cd $SAHANAHOME/eden/models
cp ../modules/templates/000_config.py .
sed -i 's|FINISHED_EDITING_CONFIG_FILE = False|settings.base.migrate = True|' $CONFIG
sed -i 's|settings.base.migrate = False|settings.base.migrate = True|' $CONFIG
sed -i 's|settings.base.debug = False|settings.base.debug = True|' $CONFIG
sed -i 's|#settings.base.prepopulate += ("default", "default/users")|settings.base.prepopulate += ("default", "default/users")|' $CONFIG

# Helper scripts that make things little easier...
cd $SAHANAHOME

# ...w2p
cat << "EOF" > "w2p"
#!/bin/bash
cd web2py
if [ $# -eq 1 ]; then
    python web2py.py -S eden -M -R $1
else
    python web2py.py -S eden -M
fi
EOF
chmod +x w2p

# ...run
cat << "EOF" > "run"
#!/bin/bash
cd web2py
python web2py.py -a testing --interfaces "127.0.0.1:8000"
EOF
chmod +x run

# ...clean
cat << "EOF" > "clean"
#!/bin/bash
cd eden
rm -rf databases/*
rm -rf errors/*
rm -rf uploads/*
rm -rf sessions/*
cd ../web2py
python web2py.py -S eden -M -R applications/eden/static/scripts/tools/noop.py
EOF
chmod +x clean

# Finally, run prepop
cd $SAHANAHOME/web2py
python web2py.py -S eden -M -R applications/eden/static/scripts/tools/noop.py

# And that was it...
echo ""
echo "Done."
