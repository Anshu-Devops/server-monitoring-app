
pipeline {
    agent any

    environment {
        AWS_DEFAULT_REGION = 'ap-south-1'
        ECR_REPOSITORY = 'server-monitoring-app'

        // Replace with Terraform outputs
        APP_HOST = '3.7.253.24'
        S3_BUCKET = 'server-monitoring-app-239711841813-fe3898e9'
    }

    stages {

        stage('Checkout') {
            steps {
                checkout scm
            }
        }

        stage('Python Validation and Tests') {
            steps {
                sh '''
                    python3 -m venv .venv
                    . .venv/bin/activate

                    pip install -r requirements-dev.txt

                    python -m py_compile app.py
                    python -m pytest -v
                '''
            }
        }

        stage('Build Docker Image') {
            steps {
                script {
                    env.ACCOUNT_ID = sh(
                        script: 'aws sts get-caller-identity --query Account --output text',
                        returnStdout: true
                    ).trim()

                    env.ECR_REGISTRY =
                        "${env.ACCOUNT_ID}.dkr.ecr.${env.AWS_DEFAULT_REGION}.amazonaws.com"

                    env.IMAGE_URI =
                        "${env.ECR_REGISTRY}/${env.ECR_REPOSITORY}:${env.BUILD_NUMBER}"
                }

                sh '''
                    docker build -t "$IMAGE_URI" .
                '''
            }
        }

        stage('Push Image to ECR') {
            steps {
                sh '''
                    aws ecr get-login-password \
                      --region "$AWS_DEFAULT_REGION" |
                    docker login \
                      --username AWS \
                      --password-stdin "$ECR_REGISTRY"

                    docker push "$IMAGE_URI"
                '''
            }
        }

        stage('Deploy to EC2') {
            steps {
                sshagent(credentials: ['app-ec2-ssh']) {

                    sh '''
                        ssh -o StrictHostKeyChecking=yes \
                            ubuntu@"$APP_HOST" \
                            "aws ecr get-login-password --region $AWS_DEFAULT_REGION | sudo docker login --username AWS --password-stdin $ECR_REGISTRY"

                        ssh -o StrictHostKeyChecking=yes \
                            ubuntu@"$APP_HOST" \
                            "sudo docker pull $IMAGE_URI"

                        ssh -o StrictHostKeyChecking=yes \
                            ubuntu@"$APP_HOST" \
                            "sudo docker rm -f monitor-app || true"

                        ssh -o StrictHostKeyChecking=yes \
                            ubuntu@"$APP_HOST" \
                            "sudo docker run -d \
                              --name monitor-app \
                              --restart unless-stopped \
                              -p 5000:5000 \
                              -e S3_BUCKET=$S3_BUCKET \
                              -e AWS_REGION=$AWS_DEFAULT_REGION \
                              $IMAGE_URI"
                    '''
                }
            }
        }

        stage('Health Check') {
            steps {
                sh '''
                    for i in $(seq 1 12); do
                        if curl --fail --silent \
                          "http://$APP_HOST:5000/health"; then
                            echo "Application health check passed"
                            exit 0
                        fi

                        echo "Waiting for application..."
                        sleep 10
                    done

                    echo "Application health check failed"
                    exit 1
                '''
            }
        }
    }

    post {
        success {
            echo 'Deployment completed successfully!'
        }

        failure {
            echo 'Pipeline failed. Check the console logs.'
        }
    }
}
