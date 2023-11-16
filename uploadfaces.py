
#Copyright 2018 Amazon.com, Inc. or its affiliates. All Rights Reserved.
#PDX-License-Identifier: MIT-0 (For details, see https://github.com/awsdocs/amazon-rekognition-developer-guide/blob/master/LICENSE-SAMPLECODE.)

import boto3
import glob

def find_face_local_file(photo):

    client=boto3.client('rekognition')
   
    print(photo)
    with open(photo, 'rb') as image:
        response = client.search_faces_by_image(
            Image={'Bytes': image.read()},
            CollectionId='tedai-hackathon',
            FaceMatchThreshold=90,
            MaxFaces=2
        )
    print(response)    

def index_face_local_file(photo, photoId):


    client=boto3.client('rekognition')
   
    print(photo)
    with open(photo, 'rb') as image:
        response = client.index_faces(
            Image={'Bytes': image.read()},
            CollectionId='tedai-hackathon',
            ExternalImageId=photoId,
            DetectionAttributes=['ALL']
            )
        
    print(response)    

# def detect_labels_local_file(photo):

#     client=boto3.client('rekognition')
   
#     with open(photo, 'rb') as image:
#         response = client.detect_labels(Image={'Bytes': image.read()})
        
#     print('Detected labels in ' + photo)    
#     for label in response['Labels']:
#         print (label['Name'] + ' : ' + str(label['Confidence']))

#     return len(response['Labels'])

def main():
    reindex = True

    photos = [
        # {
        #     "photo": "./photos/face-josephine.png",
        #     "id": "josephine"
        # },
        # {
        #     "photo": "./photos/face-kiel.png",
        #     "id": "kiel"
        # },
        # {
        #     "photo": "./photos/face-ronan.png",
        #     "id": "ronan"
        # },
        # {
        #     "photo": "./photos/face-bart.png",
        #     "id": "bart"
        # },
        {
            "photo": "./photos/face-travis.png",
            "id": "travis"
        },
    ]

    if reindex:
        for f in glob.glob("./photos/face*.png"):
            print(f)
            print(f.split("-")[1].split(".")[0])
            index_face_local_file(f, f.split("-")[1].split(".")[0])

    find_face_local_file("./photos/test/bart-test-2.png")

if __name__ == "__main__":
    main()