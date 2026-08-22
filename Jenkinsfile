pipeline {
    agent any

    options {
        timestamps()
        timeout(time: 20, unit: 'MINUTES')
        buildDiscarder(logRotator(numToKeepStr: '20'))
        disableConcurrentBuilds()
    }

    triggers {
        githubPush()
        pollSCM('H/2 * * * *')
    }

    environment {
        VENV              = "${WORKSPACE}/.venv"
        // Branch jobs run in parallel on separate executors, and the pytest fixture
        // seeds a fixed _id, so a shared database makes concurrent branches collide.
        TEST_MONGO_URI    = "mongodb://mongo:27017/test_student_db_${env.BRANCH_NAME.replaceAll('[^A-Za-z0-9_]', '_')}"
        STAGING_MONGO_URI = 'mongodb://mongo:27017/staging_student_db'
        STAGING_HOME      = '/var/jenkins_home/staging/flask_practice'
        STAGING_PORT      = '5000'
        SECRET_KEY        = credentials('flask-secret-key')
        EMAIL_RECIPIENTS  = 'devops-team@example.com'
        // gunicorn is started detached; without this Jenkins reaps it at build end.
        JENKINS_NODE_COOKIE = 'dontKillMe'
    }

    stages {
        stage('Checkout') {
            steps {
                checkout scm
                sh 'git --no-pager log -1 --pretty="Building %h on %d by %an: %s"'
            }
        }

        stage('Build') {
            steps {
                sh '''
                    set -eux
                    python3 -m venv "$VENV"
                    "$VENV/bin/pip" install --upgrade pip wheel
                    "$VENV/bin/pip" install -r requirements.txt
                    "$VENV/bin/pip" install pytest-html
                    "$VENV/bin/pip" check
                '''
            }
        }

        stage('Test') {
            environment {
                MONGO_URI = "${TEST_MONGO_URI}"
            }
            steps {
                sh '''
                    set -eux
                    mkdir -p reports
                    "$VENV/bin/python" -m pytest -v \
                        --junitxml=reports/junit.xml \
                        --html=reports/pytest-report.html --self-contained-html
                '''
            }
            post {
                always {
                    junit testResults: 'reports/junit.xml', allowEmptyResults: false
                    archiveArtifacts artifacts: 'reports/**', fingerprint: true, allowEmptyArchive: true
                }
            }
        }

        stage('Deploy to Staging') {
            when {
                branch 'main'
            }
            environment {
                MONGO_URI = "${STAGING_MONGO_URI}"
            }
            steps {
                sh '''
                    set -eux

                    # Stop the previously deployed instance, if any.
                    if [ -f "$STAGING_HOME/gunicorn.pid" ]; then
                        kill "$(cat "$STAGING_HOME/gunicorn.pid")" 2>/dev/null || true
                        sleep 2
                        rm -f "$STAGING_HOME/gunicorn.pid"
                    fi

                    # Publish this build's code into the staging release directory.
                    rm -rf "$STAGING_HOME"
                    mkdir -p "$STAGING_HOME"
                    cp -R app.py templates requirements.txt "$STAGING_HOME/"

                    python3 -m venv "$STAGING_HOME/venv"
                    "$STAGING_HOME/venv/bin/pip" install --upgrade pip wheel
                    "$STAGING_HOME/venv/bin/pip" install -r "$STAGING_HOME/requirements.txt"

                    cd "$STAGING_HOME"
                    MONGO_URI="$MONGO_URI" SECRET_KEY="$SECRET_KEY" \
                        ./venv/bin/gunicorn app:app \
                            --bind "0.0.0.0:$STAGING_PORT" \
                            --workers 2 \
                            --pid "$STAGING_HOME/gunicorn.pid" \
                            --access-logfile "$STAGING_HOME/access.log" \
                            --error-logfile "$STAGING_HOME/error.log" \
                            --daemon
                '''
            }
        }

        stage('Staging Smoke Test') {
            when {
                branch 'main'
            }
            steps {
                sh '''
                    set -eux
                    for attempt in $(seq 1 15); do
                        code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$STAGING_PORT/" || true)"
                        if [ "$code" = "200" ]; then
                            echo "Staging is serving HTTP $code on port $STAGING_PORT"
                            exit 0
                        fi
                        echo "attempt $attempt: staging not ready yet (got '$code')"
                        sleep 2
                    done
                    echo "Staging failed to become healthy; dumping error log:"
                    tail -n 50 "$STAGING_HOME/error.log" || true
                    exit 1
                '''
            }
        }
    }

    post {
        success {
            emailext(
                to: "${EMAIL_RECIPIENTS}",
                subject: "SUCCESS: ${env.JOB_NAME} #${env.BUILD_NUMBER}",
                mimeType: 'text/html',
                body: """
                    <h2>Build succeeded</h2>
                    <ul>
                      <li><b>Job:</b> ${env.JOB_NAME}</li>
                      <li><b>Build:</b> #${env.BUILD_NUMBER}</li>
                      <li><b>Branch:</b> ${env.BRANCH_NAME}</li>
                      <li><b>Console:</b> <a href="${env.BUILD_URL}console">${env.BUILD_URL}console</a></li>
                    </ul>
                    <p>Tests passed and the application was deployed to the staging environment.</p>
                """
            )
        }
        failure {
            emailext(
                to: "${EMAIL_RECIPIENTS}",
                subject: "FAILURE: ${env.JOB_NAME} #${env.BUILD_NUMBER}",
                mimeType: 'text/html',
                attachLog: true,
                body: """
                    <h2>Build failed</h2>
                    <ul>
                      <li><b>Job:</b> ${env.JOB_NAME}</li>
                      <li><b>Build:</b> #${env.BUILD_NUMBER}</li>
                      <li><b>Branch:</b> ${env.BRANCH_NAME}</li>
                      <li><b>Console:</b> <a href="${env.BUILD_URL}console">${env.BUILD_URL}console</a></li>
                    </ul>
                    <p>The full console log is attached.</p>
                """
            )
        }
        always {
            cleanWs(deleteDirs: true, notFailBuild: true)
        }
    }
}
